import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'mpv_ipc_protocol.dart';
import 'mpv_pipe_transport.dart';
import 'mpv_player.dart'
    show MpvController, MpvEvent, MpvPlaybackRestart, MpvShutdown, MpvState, MpvTrack;

/// A drop-in replacement for [MpvPlayer] that keeps mpv in a **separate
/// process** and drives it through its JSON IPC named pipe.
///
/// The public surface intentionally matches MpvPlayer so [MpvBackend] can
/// switch over without changes. Only the Windows desktop build uses this;
/// Linux/Android keep the in-process FFI path.
final class MpvIpcPlayer implements MpvController {
  MpvIpcPlayer._({
    required Map<String, String> options,
    required this.logLevel,
  })  : _options = Map.unmodifiable(options),
        state = ValueNotifier(const MpvState()),
        _events = StreamController<MpvEvent>.broadcast(sync: true);

  final Map<String, String> _options;
  final String logLevel;

  final ValueNotifier<MpvState> state;
  final StreamController<MpvEvent> _events;
  Stream<MpvEvent> get events => _events.stream;

  /// IPC has no mpv_handle pointer. Return a stable non-zero token; only the
  /// Linux external-texture path consumes `address`, and IPC is Windows-only.
  int get address => 1;

  Process? _process;
  MpvPipeTransport? _transport;
  String? _pipeName;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _disposed = false;
  bool _starting = false;
  bool _intentionalExit = false;
  bool _restarting = false;
  DateTime? _lastCrash;

  int _requestId = 0;
  final Map<int, Completer<Object?>> _replies = {};

  // create() returns before _start() finishes spawning mpv and connecting the
  // pipe. Commands issued in that window (notably load-script from the backend)
  // must be queued instead of dropped, or the OSD script never loads.
  final List<String> _pendingWrites = [];
  // Snapshot of the first-start commands (load-script, localized strings,
  // config...). Replayed after a crash restart so the OSD comes back too.
  List<String> _startupLines = const [];

  /// The last loaded URL, kept so a crashed player can be brought back.
  String? _lastLoadCommand;
  Duration _lastPosition = Duration.zero;

  static MpvIpcPlayer create({
    required Map<String, String> options,
    String logLevel = 'warn',
    String? executable,
  }) {
    final player = MpvIpcPlayer._(options: options, logLevel: logLevel);
    player._exe = executable ?? _defaultExecutable();
    player._start();
    return player;
  }

  late final String _exe;

  static String _defaultExecutable() {
    // The standalone player ships in a `player/` subfolder next to the main
    // executable so its DLLs stay isolated from the Flutter runner.
    final dir = Platform.resolvedExecutable;
    final slash = dir.lastIndexOf(Platform.pathSeparator);
    final base = slash >= 0 ? dir.substring(0, slash) : '.';
    return '$base${Platform.pathSeparator}player${Platform.pathSeparator}mpv.exe';
  }

  Future<void> _start() async {
    if (_starting) return;
    _starting = true;
    _pipeName = 'aushd_mpv_${DateTime.now().microsecondsSinceEpoch}_$_requestId';
    final args = <String>[
      '--no-config',
      '--input-ipc-server=\\\\.\\pipe\\$_pipeName',
      // buildMpvOptions already supplies idle/force-window/vo/gpu settings.
      // wid is a HWND decimal string; Windows accepts it across processes and
      // mpv attaches its own VO child window to our host window (verified).
      for (final entry in _options.entries) '--${entry.key}=${entry.value}',
      if (logLevel.isNotEmpty) '--msg-level=all=$logLevel',
    ];
    try {
      // Use the normal mode (not detached): we need stdout/stderr/exitCode to
      // detect crashes and auto-restart. On Windows the player is a child of
      // this process and is killed in dispose(), so no orphan is left behind.
      _process = await Process.start(_exe, args);
      _attachProcessWatch();
      _transport = await MpvPipeTransport.connect(
        pipeName: _pipeName!,
        onLine: _onLine,
        onDone: _onPipeDone,
      );
      // Flush commands that arrived before the pipe was ready (first start:
      // load-script/strings/config; restart: replayed startup commands).
      for (final line in _pendingWrites) {
        _transport!.write(line);
      }
      if (_startupLines.isEmpty) _startupLines = List<String>.from(_pendingWrites);
      _pendingWrites.clear();
      _observeAll();
      _starting = false;
    } catch (e) {
      _starting = false;
      debugPrint('[mpv-ipc] start failed: $e');
      _events.add(MpvShutdown());
    }
  }

  void _attachProcessWatch() {
    final process = _process!;
    process.exitCode.then((code) async {
      if (_disposed) return;
      debugPrint('[mpv-ipc] player process exited with $code');
      if (_intentionalExit) {
        _events.add(MpvShutdown());
        return;
      }
      // The whole point of isolation: a GPU crash in the player process must
      // not take down the app. Bring it back with the last file/position.
      if (_lastLoadCommand == null || _restarting) {
        _events.add(MpvShutdown());
        return;
      }
      final now = DateTime.now();
      if (_lastCrash != null && now.difference(_lastCrash!).inSeconds < 3) {
        debugPrint('[mpv-ipc] repeated crash in <3s, giving up to avoid a loop');
        _events.add(MpvShutdown());
        return;
      }
      _lastCrash = now;
      _restarting = true;
      debugPrint('[mpv-ipc] auto-restarting player after crash');
      await restart();
      _restarting = false;
    });
    _stdoutSub = process.stdout
        .transform(const SystemEncoding().decoder)
        .listen((s) => debugPrint('[mpv] $s'.trimRight()));
    _stderrSub = process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((s) => debugPrint('[mpv/err] $s'.trimRight()));
  }

  void _onLine(String line) {
    final msg = IpcMessage.parse(line);
    if (msg == null) return;
    if (msg.replyId != null) {
      // mpv assigns request_id 0 to replies for commands we sent without one
      // (e.g. observe_property). Those have no waiter; ignore them.
      final completer = _replies.remove(msg.replyId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(msg.replyError == 'success' ? msg.replyData : null);
      }
      return;
    }
    if (msg.isPropertyChange) {
      _onProperty(msg.property!, msg.propertyValue);
      return;
    }
    final event = msg.event;
    if (event != null) {
      if (event is MpvPlaybackRestart) {
        _lastPosition = state.value.position;
      }
      _events.add(event);
    }
  }

  void _onPipeDone() {
    if (_disposed) return;
    debugPrint('[mpv-ipc] pipe closed');
  }

  Future<Object?> _request(List<String> args) async {
    if (_disposed) return null;
    final id = ++_requestId;
    final completer = Completer<Object?>();
    _replies[id] = completer;
    final line = ipcCommand(args, requestId: id);
    final transport = _transport;
    if (transport == null) {
      // Pipe not connected yet. Queue the serialized command; _start() flushes
      // it as soon as mpv's IPC server is reachable. Dropping it here was the
      // reason the OSD script never loaded in the isolated-process build.
      _pendingWrites.add(line);
    } else {
      transport.write(line);
    }
    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _replies.remove(id);
      return null;
    });
  }

  void command(List<String> args) {
    if (_disposed) return;
    if (args.isNotEmpty && args.first == 'loadfile') {
      _lastLoadCommand = ipcCommand(args);
    }
    _request(args);
  }

  void commandAsync(List<String> args) => command(args);

  void setProperty(String name, String value) => command(['set_property', name, value]);

  Future<String?> getString(String name) async {
    final data = await _request(['get_property', name]);
    return data?.toString();
  }

  void scriptMessage(String script, List<String> args) =>
      commandAsync(['script-message-to', script, ...args]);

  void _observeAll() {
    for (var i = 0; i < ipcObservedProperties.length; i++) {
      final (name, _) = ipcObservedProperties[i];
      _transport?.write(ipcObserve(i, name));
    }
  }

  void _onProperty(String name, Object? value) {
    final s = state.value;
    double dbl() => (value as num?)?.toDouble() ?? 0;
    bool flag() => value == true || value == 1;
    Duration secs(double s) => Duration(microseconds: (s * 1e6).round());

    state.value = switch (name) {
      'time-pos' => s.copyWith(position: secs(dbl())),
      'duration' => s.copyWith(duration: secs(dbl())),
      'pause' => s.copyWith(paused: flag()),
      'paused-for-cache' => s.copyWith(buffering: flag()),
      'seeking' => s.copyWith(seeking: flag()),
      'cache-buffering-state' => s.copyWith(cacheBufferingPercent: dbl().toInt()),
      'demuxer-cache-time' => s.copyWith(cacheAhead: secs(dbl())),
      'eof-reached' => s.copyWith(eofReached: flag()),
      'idle-active' => s.copyWith(idle: flag()),
      'track-list' => s.copyWith(tracks: _parseTracks(value)),
      'volume' => s.copyWith(volume: dbl()),
      'mute' => s.copyWith(muted: flag()),
      'video-params' => s.copyWith(
          videoParams: value is Map
              ? value.cast<String, Object?>()
              : const {}),
      'hwdec-current' => s.copyWith(hwdec: value?.toString() ?? ''),
      'container-fps' => s.copyWith(containerFps: value is num ? value.toDouble() : null),
      _ => s,
    };
  }

  static List<MpvTrack> _parseTracks(Object? raw) {
    if (raw is! List) return const [];
    return [for (final t in raw) ?_trackFromJson(t)];
  }

  static MpvTrack? _trackFromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, Object?>();
    final id = m['id'];
    final type = m['type'];
    if (id is! num || type is! String) return null;
    return MpvTrack(
      id: id.toInt(),
      type: type,
      ffIndex: (m['ff-index'] as num?)?.toInt(),
      title: m['title'] as String?,
      lang: m['lang'] as String?,
      codec: m['codec'] as String?,
      external: m['external'] == true,
      externalFilename: m['external-filename'] as String?,
      selected: m['selected'] == true,
      isDefault: m['default'] == true,
      forced: m['forced'] == true,
      channels: (m['demux-channel-count'] as num?)?.toInt(),
    );
  }

  /// Brings a crashed player back with the same options and the last file.
  Future<void> restart() async {
    if (_disposed) return;
    _transport?.close();
    _transport = null;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _replies.clear();
    _starting = false;
    // The new mpv process has a fresh Lua VM, so the OSD script and its state
    // must be re-injected. Queue the startup snapshot before _start connects;
    // it will be flushed together with any early commands.
    _pendingWrites.addAll(_startupLines);
    // Wait briefly for the old process to fully exit before rebinding a pipe.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _start();
    if (_lastLoadCommand != null) {
      _transport?.write(_lastLoadCommand!);
      if (_lastPosition > Duration.zero) {
        command(['seek', '${_lastPosition.inMilliseconds / 1000}', 'absolute']);
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _intentionalExit = true;
    _transport?.close();
    _transport = null;
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    for (final c in _replies.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _replies.clear();
    _process?.kill();
    _process = null;
    _events.close();
    state.dispose();
  }
}
