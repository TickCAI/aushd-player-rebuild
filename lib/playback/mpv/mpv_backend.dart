import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/host.dart';
import '../../core/log/app_log.dart';
import '../../core/windows/fullscreen_controller.dart';
import '../../core/windows/native_window.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/core/gamepad.dart';
import '../../ui/player/player_osd.dart';
import '../../ui/widgets/net_image.dart';
import '../dialogue_downmix.dart';
import '../display_refresh.dart';
import '../media3/osd_model.dart';
import '../player_backend.dart';
import '../player_settings.dart';
import '../render_guard.dart';
import '../trickplay.dart';
import 'libmpv.dart' show MpvEndFileReason;
import 'mpv_options.dart';
import 'mpv_player.dart';
import 'video_host.dart';

typedef _TrickFile = ({String path, int w, int h});

final class MpvBackend implements PlayerBackend {
  MpvBackend({
    required this._navigator,
    required this._settings,
    required this.l10n,
    this.acceptInvalidCertificates = false,
  });

  final NavigatorState _navigator;
  final PlayerSettings _settings;

  final L10n l10n;
  final bool acceptInvalidCertificates;

  late final MpvPlayer _mpv;
  final _state = ValueNotifier(const PlayerState());
  final _events = StreamController<PlayerEvent>.broadcast(sync: true);
  final _osdReady = Completer<void>();
  final _refresh = DisplayRefreshMatcher();
  StreamSubscription<MpvEvent>? _sub;
  late final OsdModel _curtain = OsdModel(
    state: _state,
    send: (name, [arg]) => _events.add(PlayerOsdEvent(name, arg)),
    togglePause: () {},
    seekTo: (_) {},
  );
  Route<void>? _route;
  bool _videoShown = false;

  bool _framed = false;

  /// Set once [open] has run; nothing may talk to a player that never existed.
  /// Guards every public method that would touch a torn-down player.
  bool _closed = false;

  /// `close()` must be idempotent: the ESC path, the room path and the
  /// crash-recovery path can all reach it within the same frame.
  bool _closing = false;

  /// Time the video host is given to stop presenting before it is hidden.
  /// Two frames at 120 Hz is 17 ms, so 150 ms is generous at any refresh rate -
  /// the point is that the VO has stopped touching the swapchain before it is
  /// hidden and later destroyed.
  /// How long the VO is left alone after it has been stopped, before the next
  /// step of the teardown touches its window.
  ///
  /// 150 ms was enough on paper (two frames at 120 Hz is 17 ms) and not enough
  /// in practice: the 2026-11-18 dumps show AMD's user-mode worker faulting on a
  /// null callback about five seconds *after* the player was already destroyed,
  /// which is what a still-queued submission looks like once its object is gone.
  /// The dwell covers the case where the queue is deeper than one frame.
  static const _quiesceDwell = Duration(milliseconds: 400);

  @override
  ValueListenable<PlayerState> get state => _state;

  @override
  Stream<PlayerEvent> get events => _events.stream;

  @override
  bool get selectsFileTracks => true;

  @override
  bool get streamSubtitles => false;

  @override
  String? get textSubtitleFormat => null;

  /// Always-on mpv log, kept short.
  ///
  /// The three crashes on record happened inside `amdxx64.dll`, and the only
  /// thread that could name the failing mpv call is mpv's own vo/gpu log - so
  /// it must exist even when the user never turned on "detailed log". Volume is
  /// bounded by keeping only the two most recent sessions on disk.
  String? _mpvLogPath() {
    final path = AppLog.sidePath('mpv');
    if (path == null) return null;
    try {
      final dir = Directory(p.dirname(path));
      if (!dir.existsSync()) return path;
      final old = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('mpv-') && f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final f in old.skip(2)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
    return path;
  }

  /// One line per playback session describing the whole render stack.
  ///
  /// Without this, a dump can only be matched to "whatever the settings were at
  /// the time" - and the settings were the thing that had silently changed
  /// between the three crashes on record.
  Future<void> _logSessionMode(String? logFile, MpvMode mode, String hwdec) async {
    var hdr = 'unknown';
    try {
      final status = await NativeWindow.hdrStatus().timeout(const Duration(seconds: 2));
      hdr = status.enabled ? 'on' : (status.supported ? 'off' : 'unsupported');
    } catch (_) {}
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    final display = displays.isEmpty ? null : displays.first;
    AppLog.write('[session] mode ${mode.describe()} hwdec=$hwdec '
        'flip=${mode.api == 'd3d11' ? 'no' : 'n/a'} '
        'fullscreen=${FullscreenController.instance.isFullscreen} hdr=$hdr '
        'display=${display == null ? 'none' : '${display.size.width.round()}x${display.size.height.round()}'
            '@${display.refreshRate.toStringAsFixed(2)}Hz scale=${display.devicePixelRatio}'} '
        'mpvLog=${logFile == null ? 'off' : p.basename(logFile)}');
  }

  @override
  Future<void> open() async {
    // A stuck native "create video host" call used to leave playItem awaiting
    // forever, with no player page and no log line at all. Bound it so the
    // launcher can report the failure instead of silently doing nothing.
    final wid = Host.isLinux
        ? null
        : await VideoHost.create().timeout(const Duration(seconds: 8),
            onTimeout: () => throw StateError('the video host did not respond within 8 s'));
    final logFile = _mpvLogPath();
    // Resolved once so the options map, the mode memory and the log line cannot
    // disagree about which driver path this session is about to take.
    final mode = resolveMpvMode(settings: _settings, avoid: RenderGuard.avoid);
    final options = buildMpvOptions(
      wid: wid,
      settings: _settings,
      mode: mode,
      acceptInvalidCertificates: acceptInvalidCertificates,
      logFile: logFile,
      osdFontsDir: Host.isLinux ? p.join(p.dirname(_osdScriptPath()), 'fonts') : null,
    );
    final hwdec = options['hwdec'] ?? _settings.hwdec;
    debugPrint('[mpv] options: ${[for (final e in options.entries) if (e.key != 'wid') '${e.key}=${e.value}'].join(' ')}');
    if (logFile != null) debugPrint('[mpv] detailed log: $logFile');
    // Recorded before mpv exists: a native fault inside create() has to be
    // attributable to this exact render path, not to "whatever the settings
    // happened to be".
    await RenderGuard.markPlaybackStarted(
      mode: RenderGuard.fingerprint(
        vo: mode.vo,
        api: mode.api,
        gpuContext: mode.gpuContext,
        hwdec: hwdec,
      ),
    );
    unawaited(_logSessionMode(logFile, mode, hwdec));
    try {
      _mpv = MpvPlayer.create(options: options, logLevel: _settings.detailedLog ? 'info' : 'warn');
    } catch (e) {
      debugPrint('[mpv] initialization failed with these options: $e');
      rethrow;
    }
    if (Host.isLinux) {
      await VideoHost.attach(_mpv.address).timeout(const Duration(seconds: 8),
          onTimeout: () => throw StateError('attaching the video host timed out'));
    }
    _sub = _mpv.events.listen(_onEvent);
    VideoHost.onInput = _mpv.commandAsync;
    _mpv.state.addListener(_onState);

    final route = PlayerOsdRoute(model: _curtain, controls: false);
    _route = route;
    unawaited(_navigator.push(route));

    await _loadUserConfig();
    final script = _osdScriptPath();
    debugPrint('[mpv] loading the OSD ${File(script).existsSync() ? '' : '(MISSING!) '}$script');
    _mpv.command(['load-script', script]);
    _mpv.setProperty('user-data/zerk/fullscreen', (await NativeWindow.isFullScreen()) ? 'yes' : 'no');
    await _osdReady.future.timeout(const Duration(seconds: 3), onTimeout: () {
      debugPrint('[mpv] the OSD script did not report ready within 3 s: the player UI will be missing');
    });
    osd('strings', _osdStrings(l10n));
    osd('downmix', {
      'on': _settings.stereoDownmix,
      'label': DialogueDownmix.mpvLabel,
      'af': DialogueDownmix.mpvFilter,
      'spdif': _settings.mpvSpdif,
    });
  }

  static Map<String, String> _osdStrings(L10n l) => {
        'back': l.back,
        'seek_back': l.seekBack('{n}'),
        'seek_forward': l.seekForward('{n}'),
        'mute': l.mute,
        'unmute': l.unmute,
        'play': l.play,
        'pause': l.pause,
        'audio': l.audio,
        'subtitles': l.subtitles,
        'chapters': l.chapters,
        'next_episode': l.nextEpisode,
        'settings': l.settings,
        'full_screen': l.fullScreen,
        'off': l.subtitleOff,
        'chapter': l.chapterNumber('{n}'),
        'version': l.version,
        'quality': l.playerQuality,
        'aspect_original': l.aspectOriginal,
        'aspect_original_detail': l.aspectOriginalDetail,
        'aspect_flat': l.aspectFlat,
        'aspect_scope': l.aspectScope,
        'aspect_zoom': l.aspectZoom,
        'aspect_zoom_detail': l.aspectZoomDetail,
        'aspect_stretch': l.aspectStretch,
        'aspect_stretch_detail': l.aspectStretchDetail,
        'aspect_ratio': l.aspectRatio,
        'aspect_toast': l.aspectToast('{n}'),
        'playback_speed': l.playbackSpeed,
        'subtitle_delay': l.subtitleDelay,
        'audio_delay': l.audioDelay,
        'subtitle_size': l.subtitleSize,
        'slider_hint': l.sliderHint,
        'search_subtitles': l.searchSubtitles,
        'searching': l.subtitleSearching,
        'no_subtitles_found': l.subtitleSearchEmpty,
        'playback_info': l.playbackInfo,
        'playback_info_detail': l.playbackInfoDetail,
        'hdr_on': l.badgeHdrOn,
        'tone_mapped': l.badgeToneMapped,
        'muted': l.muted,
        'press_back': l.pressBackToReturn,
        'skip_intro': l.skipIntro,
        'up_next': l.upNext,
        'starts_in': l.startsIn('{n}'),
        'intro_skipped': l.introSkipped,
        'play_now': l.playNow,
        'keep_watching': l.keepWatching,
        'stereo_downmix': l.stereoDownmix,
        'stereo_downmix_detail': l.stereoDownmixDetail,
        'on': l.toggleOn,
      };

  Future<void> _showVideo(bool show) async {
    // A late OSD phase change must not re-show a video host that the teardown
    // has already hidden - that is a swapchain rebuild on the way out.
    if (_closed) return;
    if (show == _videoShown) return;
    _videoShown = show;
    debugPrint('[mpv] video window ${show ? 'shown' : 'hidden'}');
    Gamepad.playerSink = show ? (key) => _mpv.commandAsync(['keypress', key]) : null;
    await (show ? VideoHost.show() : VideoHost.hide());
  }

  /// The native video window follows the picture, not the OSD phase.
  ///
  /// It used to be driven by `_curtain.phase == 'playing'`, so every OSD phase
  /// change - loading, track switch, the pause hint - hid and re-showed the
  /// mpv VO child window. Each re-show reconfigures the VO and rebuilds the
  /// swapchain inside the driver that is already the suspect here. mpv draws
  /// its own OSD on top of the video anyway (`zerk_osd.lua`), so the window has
  /// no reason to disappear after the first frame has been presented.
  void _syncVideoWindow() {
    if (_closed) return;
    unawaited(_showVideo(_framed));
  }

  @override
  void load(Uri url, {Duration? start, int? audioOrdinal, int? subtitleOrdinal, String? dolbyVision}) {
    final opts = <String>[
      if (start != null && start > Duration.zero) 'start=${start.inMilliseconds / 1000}',
      'aid=${audioOrdinal ?? 'auto'}',
      'sid=${subtitleOrdinal ?? 'no'}',
    ];
    _mpv.command(['loadfile', url.toString(), 'replace', '-1', opts.join(',')]);
  }

  @override
  void selectTrack(String type, String? id) => _mpv.setProperty(type == 'audio' ? 'aid' : 'sid', id ?? 'no');

  @override
  void addSubtitle(Uri url, {required String format, required String title, String? language}) =>
      _mpv.commandAsync(['sub-add', url.toString(), 'select', title, language ?? '']);

  @override
  void attachSecondarySubtitle(String filePath) {
    // Add the ASS as a *non-selected* subtitle, then point the secondary slot
    // at it. The primary subtitle (sid) is untouched, so danmaku overlays
    // alongside real subs. secondary-sid=auto picks the added track.
    _mpv.commandAsync(['sub-add', filePath, 'auto', 'danmaku', '']);
    _mpv.setProperty('secondary-sid', 'auto');
  }

  @override
  void detachSecondarySubtitle() => _mpv.setProperty('secondary-sid', 'no');

  @override
  void osd(String command, Object? data) {
    // `_curtain` is disposed at the end of close(); notifying it afterwards
    // throws into the synchronous event stream and used to break the pump.
    if (_closed) return;
    if (command == 'trickplay') return _setTrickplay(data is Trickplay ? data : null);
    if (command == 'toast' && data is Map) return unawaited(_sendPictureToast(data));
    final payload = data is String ? data : jsonEncode(data);
    if (command != 'strings') {
      debugPrint('[osd] -> $command ${payload.length > 300 ? '${payload.substring(0, 300)}...' : payload}');
    }
    _mpv.scriptMessage('zerk_osd', [command, payload]);
    if (command == 'next') unawaited(_sendNextImage(data is Map ? data['image'] as String? : null));
    if (command != 'state') return;
    _curtain.handle(command, data);
    // A new load has no frame yet: drop the window so the previous picture
    // cannot linger over the loading card. Every other phase keeps it up.
    if (_curtain.phase == 'loading') _framed = false;
    _syncVideoWindow();
  }

  @override
  void setPaused(bool paused) => _mpv.setProperty('pause', paused ? 'yes' : 'no');

  @override
  void seek(Duration position) => _mpv.commandAsync(['seek', '${position.inMilliseconds / 1000}', 'absolute']);

  @override
  bool get adjustsSpeed => true;

  @override
  void setSpeed(double speed) => _mpv.setProperty('speed', '$speed');

  @override
  void setSubtitleScale(double scale) => _mpv.setProperty('sub-scale', scale.toStringAsFixed(2));

  @override
  Future<double?> matchRefreshRate(double fps) async => _refresh.matchFrameRate(fps);

  @override
  Future<DisplayHdrStatus> displayHdr() => NativeWindow.hdrStatus();

  @override
  Future<void> close() async {
    if (_closing) {
      debugPrint('[mpv] close() re-entered; ignoring');
      return;
    }
    _closing = true;
    final closeWatch = Stopwatch()..start();
    AppLog.write('[session] close start (vo-configured=${_mpv.getString('vo-configured')})');

    // 1. Stop reacting to the events this teardown is about to cause, and stop
    //    feeding input into a command queue that is going away. Doing this
    //    first also means a late OSD callback cannot resurrect the player.
    await _sub?.cancel();
    _mpv.state.removeListener(_onState);
    VideoHost.onInput = null;
    Gamepad.playerSink = null;

    // 2. Stop decoding and presenting while mpv is still healthy, and give the
    //    VO a moment to drop its frame. `keep-open` can hold the VO open, so a
    //    timeout here is expected, not a failure - it is recorded either way.
    //    Pausing first means the driver stops receiving new frames *before* its
    //    swapchain disappears under it, instead of draining a queue whose
    //    objects are being freed at the same time.
    _mpv.setProperty('pause', 'yes');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _mpv.command(['stop']);
    final quiesced =
        await _waitVoConfigured(false, const Duration(milliseconds: 600));
    AppLog.write('[vo] quiesced vo-configured=false '
        '(${quiesced ? 'reached' : 'kept open by keep-open'})');
    await Future<void>.delayed(_quiesceDwell);

    // 3. Hide the host before the VO is destroyed, so the child window is not
    //    resized or painted while it is going away.
    await VideoHost.hide();
    AppLog.write('[video_host] hidden');
    if (Host.isLinux) await VideoHost.detach();
    await Future<void>.delayed(_quiesceDwell);

    // 4. Let mpv tear its own renderer down and say so, then destroy the handle.
    //    `terminateDestroy` on a live VO joins threads while the driver is still
    //    using the device - that is the window the crash dumps landed in.
    AppLog.write('[mpv] quit sent');
    final clean = await _mpv.shutdown();
    AppLog.write('[mpv] shutdown event ${clean ? 'received' : 'TIMEOUT'}');
    _mpv.dispose();
    AppLog.write('[mpv] destroyed');
    _closed = true;

    // 5. Global display state is restored only after mpv is gone, never before:
    //    a mode switch while the VO is still presenting forces a full swapchain
    //    rebuild on the old device.
    if (_settings.keepRefreshRate) {
      _refresh.keep();
    } else {
      _refresh.restore();
    }
    AppLog.write('[refresh] restored');

    _resetTrickplay(null);
    final route = _route;
    _route = null;
    if (route != null && route.isActive) _navigator.removeRoute(route);
    _curtain.dispose();
    await _events.close();
    AppLog.write('[session] close done in ${closeWatch.elapsedMilliseconds} ms');
    // The marker is cleared after a grace period rather than now, so a fault
    // during the native teardown above is still attributed to this session.
    RenderGuard.markPlaybackFinished();
  }

  /// Polls `vo-configured` until it matches [want].
  ///
  /// Returns whether the target state was actually observed within [timeout];
  /// the caller logs the distinction instead of inventing a guarantee.
  Future<bool> _waitVoConfigured(bool want, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final value = _mpv.getString('vo-configured');
      if (value == null) return false;
      if ((value == 'yes') == want) return true;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return false;
  }

  void _onEvent(MpvEvent e) {
    switch (e) {
      case MpvFileLoaded():
        final s = _mpv.state.value;
        debugPrint('[mpv] file loaded: hwdec=${s.hwdec} video=${s.videoParams} fps=${s.containerFps}');
        _events.add(const PlayerLoaded());
      case MpvPlaybackRestart():
        if (!_framed) debugPrint('[mpv] first frame (hwdec ${_mpv.state.value.hwdec})');
        _framed = true;
        _syncVideoWindow();
      case MpvEndFile(:final reason, :final error) when reason == MpvEndFileReason.error:
        debugPrint('[mpv] end of file: ERROR $error');
        _events.add(PlayerLoadError(error));
      case MpvEndFile(:final reason):
        debugPrint('[mpv] end of file (reason $reason)');
      case MpvClientMessage(:final args) when args.firstOrNull == 'zerk-event':
        final name = args.elementAtOrNull(1);
        if (name != 'trick') debugPrint('[osd] event $name${args.length > 2 ? ' ${args[2]}' : ''}');
        switch (name) {
          case null:
            break;
          case 'ready':
            if (!_osdReady.isCompleted) _osdReady.complete();
          case 'trick':
            unawaited(_sendTrick(args.elementAtOrNull(2)));
          case 'fullscreen':
            unawaited(_toggleFullscreen());
          default:
            _events.add(PlayerOsdEvent(name, args.elementAtOrNull(2)));
        }
      case MpvShutdown():
        _events.add(const PlayerShutdown());
      default:
        break;
    }
  }

  void _onState() {
    final s = _mpv.state.value;
    _state.value = PlayerState(
      position: s.position,
      duration: s.duration,
      paused: s.paused,
      buffering: s.buffering,
      ended: s.eofReached,
      muted: s.muted,
      volume: s.volume,
      videoTransfer: s.videoParams['gamma'] as String?,
      dolbyVision: s.videoParams['colormatrix'] == 'dolbyvision',
      fps: s.containerFps,
      tracks: [
        for (final t in s.tracks)
          if (t.type == 'audio' || t.type == 'sub')
            PlayerTrack(
              id: '${t.id}',
              type: t.type,
              ordinal: t.external ? null : t.id,
              ffIndex: t.ffIndex,
              external: t.external,
              externalUrl: t.externalFilename,
              selected: t.selected,
            ),
      ],
    );
  }

  int _nextImageSerial = 0;

  Future<void> _sendNextImage(String? url) async {
    final serial = ++_nextImageSerial;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return;
    try {
      final image = await _resolve(NetImageProvider(uri, decodeWidth: _nextImageWidth));
      final dir = Directory(p.join((await getTemporaryDirectory()).path, 'zerk_play_osd'));
      await dir.create(recursive: true);
      for (final f in dir.listSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      final files = <String, String>{};
      for (final grey in [true, false]) {
        final bytes = await _cardStill(image, grey: grey);
        final file = File(p.join(dir.path, 'next-$serial-${grey ? 'grey' : 'colour'}.bgra'));
        await file.writeAsBytes(bytes, flush: true);
        files[grey ? 'grey' : 'colour'] = file.path;
      }
      image.dispose();
      if (serial != _nextImageSerial) return;
      _mpv.scriptMessage('zerk_osd', ['next-image', jsonEncode({
        'url': url,
        ...files,
        'w': _nextImageWidth,
        'h': _nextImageWidth * 9 ~/ 16,
      })]);
    } catch (e) {
      debugPrint('[mpv] up-next still failed: $e');
    }
  }

  static const _nextImageWidth = 800;

  int _toastSerial = 0;

  Future<void> _sendPictureToast(Map data) async {
    final text = data['text'] as String? ?? '';
    final serial = ++_toastSerial;
    final uri = Uri.tryParse(data['image'] as String? ?? '');
    try {
      if (uri == null) throw const FormatException('no picture');
      final image = await _resolve(NetImageProvider(uri, decodeWidth: _toastImageSize)).timeout(const Duration(seconds: 2));
      final bytes = await _roundPicture(image);
      image.dispose();
      final dir = Directory(p.join((await getTemporaryDirectory()).path, 'zerk_play_osd_toast'));
      await dir.create(recursive: true);
      for (final f in dir.listSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      final file = File(p.join(dir.path, 'toast-$serial.bgra'));
      await file.writeAsBytes(bytes, flush: true);
      if (serial != _toastSerial) return;
      _mpv.scriptMessage('zerk_osd', ['toast-image', jsonEncode({'text': text, 'image': file.path, 'size': _toastImageSize})]);
    } catch (e) {
      debugPrint('[mpv] toast picture: $e');
      if (serial == _toastSerial) _mpv.scriptMessage('zerk_osd', ['toast', text]);
    }
  }

  static const _toastImageSize = 96;

  Trickplay? _trickplay;
  int _trickGeneration = 0;
  int _trickSerial = 0;
  final _trickFiles = <int, _TrickFile>{};
  Directory? _trickDir;

  static const _trickFileLimit = 48;

  void _setTrickplay(Trickplay? trickplay) {
    if (identical(trickplay, _trickplay)) return;
    _resetTrickplay(trickplay);
    final config = trickplay == null ? null : {'interval': trickplay.interval.inMilliseconds / 1000};
    _mpv.scriptMessage('zerk_osd', ['trickplay', jsonEncode(config)]);
  }

  void _resetTrickplay(Trickplay? trickplay) {
    _trickplay = trickplay;
    _trickGeneration++;
    unawaited(_clearTrickFiles());
  }

  Future<Directory> _trickDirectory() async {
    final dir = _trickDir ??= Directory(p.join((await getTemporaryDirectory()).path, 'zerk_play_osd_trick'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _clearTrickFiles() async {
    _trickFiles.clear();
    final keep = 'trick-$_trickGeneration-';
    try {
      final dir = await _trickDirectory();
      for (final f in dir.listSync()) {
        if (p.basename(f.path).startsWith(keep)) continue;
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _sendTrick(String? arg) async {
    final trickplay = _trickplay;
    final secs = double.tryParse(arg ?? '');
    if (trickplay == null || secs == null) return;
    final serial = ++_trickSerial;
    final generation = _trickGeneration;
    final index = trickplay.indexAt(Duration(milliseconds: (secs * 1000).round()));
    final file = _trickFiles[index] ?? await _writeTrickFile(trickplay, index, generation);
    if (file == null || serial != _trickSerial || generation != _trickGeneration) return;
    _mpv.scriptMessage('zerk_osd', ['trick-image', jsonEncode({'path': file.path, 'w': file.w, 'h': file.h})]);
  }

  Future<_TrickFile?> _writeTrickFile(Trickplay trickplay, int index, int generation) async {
    final frame = await trickplay.frame(index);
    if (frame == null) return null;
    try {
      final pixels = await _framePixels(frame);
      if (generation != _trickGeneration) return null;
      final path = p.join((await _trickDirectory()).path, 'trick-$generation-$index.bgra');
      await File(path).writeAsBytes(pixels.bytes, flush: true);
      if (generation != _trickGeneration) return null;
      final file = (path: path, w: pixels.w, h: pixels.h);
      _trickFiles[index] = file;
      while (_trickFiles.length > _trickFileLimit) {
        final old = _trickFiles.remove(_trickFiles.keys.first)!;
        try {
          File(old.path).deleteSync();
        } catch (_) {}
      }
      return file;
    } catch (e) {
      debugPrint('[mpv] trickplay thumbnail: $e');
      return null;
    } finally {
      frame.dispose();
    }
  }

  static Future<({Uint8List bytes, int w, int h})> _framePixels(TrickplayFrame frame) async {
    final w = frame.source.width.round(), h = frame.source.height.round();
    final recorder = ui.PictureRecorder();
    frame.paint(Canvas(recorder), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    return (bytes: await _bgraPixels(recorder, w, h), w: w, h: h);
  }

  static Future<Uint8List> _bgraPixels(ui.PictureRecorder recorder, int w, int h) async {
    final picture = recorder.endRecording();
    final out = await picture.toImage(w, h);
    picture.dispose();
    final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    out.dispose();
    final px = data!.buffer.asUint8List();
    for (var i = 0; i < px.length; i += 4) {
      final red = px[i];
      px[i] = px[i + 2];
      px[i + 2] = red;
    }
    return px;
  }

  static Future<Uint8List> _roundPicture(ui.Image image) {
    const size = _toastImageSize;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(0, 0, size + 0.0, size + 0.0)));
    final src = Offset.zero & Size(image.width.toDouble(), image.height.toDouble());
    final fit = applyBoxFit(BoxFit.cover, src.size, const Size(size + 0.0, size + 0.0));
    canvas.drawImageRect(image, Alignment.center.inscribe(fit.source, src), const Rect.fromLTWH(0, 0, size + 0.0, size + 0.0),
        Paint()..filterQuality = FilterQuality.medium);
    return _bgraPixels(recorder, size, size);
  }

  static Future<ui.Image> _resolve(ImageProvider provider) {
    final done = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      done.complete(info.image.clone());
      info.dispose();
    }, onError: (e, _) {
      stream.removeListener(listener);
      done.completeError(e);
    });
    stream.addListener(listener);
    return done.future;
  }

  static Future<Uint8List> _cardStill(ui.Image image, {required bool grey}) {
    const w = _nextImageWidth, h = _nextImageWidth * 9 ~/ 16;
    const r = Radius.circular(36);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.clipRRect(RRect.fromLTRBAndCorners(0, 0, w.toDouble(), h.toDouble(), topLeft: r, topRight: r));
    final paint = Paint()..filterQuality = FilterQuality.medium;
    if (grey) {
      paint.colorFilter = const ColorFilter.matrix([
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0, 0, 0, 1, 0,
      ]);
    }
    final src = Offset.zero & Size(image.width.toDouble(), image.height.toDouble());
    final fit = applyBoxFit(BoxFit.cover, src.size, const Size(w + 0.0, h + 0.0));
    canvas.drawImageRect(image, Alignment.center.inscribe(fit.source, src), Offset.zero & const Size(w + 0.0, h + 0.0), paint);
    return _bgraPixels(recorder, w, h);
  }

  Future<void> _toggleFullscreen() async {
    // Routed through the controller so an OSD-driven toggle cannot overlap the
    // F11 shortcut or the boot-time transition on the same HWND.
    final applied = await FullscreenController.instance.toggleFullScreen();
    final fs = FullscreenController.instance.isFullscreen;
    _mpv.setProperty('user-data/zerk/fullscreen', fs ? 'yes' : 'no');
    if (!applied) debugPrint('[mpv] fullscreen toggle did not settle as requested');
    await VideoHost.focus();
  }

  Future<void> _loadUserConfig() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'mpv.conf'));
      if (await file.exists()) {
        debugPrint('[mpv] loading the user mpv.conf: ${file.path}');
        _mpv.command(['load-config-file', file.path]);
      }
    } catch (e) {
      debugPrint('[mpv] mpv.conf: $e');
    }
  }

  static String _osdScriptPath() => p.join(
        p.dirname(Platform.resolvedExecutable),
        'data', 'flutter_assets', 'assets', 'mpv', 'zerk_osd.lua',
      );
}
