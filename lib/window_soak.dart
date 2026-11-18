import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

import '../core/host.dart';
import '../core/windows/native_window.dart';

/// Fullscreen window soak.
///
/// Drives only the window layer (no mpv, no network, no auth), so it runs in a
/// release build and on a GPU-less CI runner. It exists to make the window and
/// fullscreen defects reproducible instead of "sometimes it crashes":
///
///  * `zerk/window` state must agree with the actual window geometry;
///  * fullscreen must cover the windowed window, identically on every round;
///  * the windowed geometry must come back exactly on the way out;
///  * concurrent toggles must not wedge the window layer;
///  * the last toggle must leave the app windowed (no leaked fullscreen state);
///  * the raster thread must keep producing frames during the transitions.
///
/// `window_manager.isFullScreen()` is recorded as a diagnostic, never as an
/// oracle: the app drives fullscreen through its own `zerk/window` channel plus
/// a `GWL_STYLE` rewrite, so the plugin's cached flag is stale by construction.
/// Grading a second, structurally unreachable authority is not a test - it is
/// the "two fullscreen authorities" defect the plan is fixing.
///
/// Enabled by `AUSHD_WINDOW_SOAK=<iterations>`; the report goes to
/// `AUSHD_SOAK_REPORT` (default `soak-report.txt` next to the executable) and
/// the process exits with
///   0 = every invariant held,
///   1 = at least one invariant was violated,
///   2 = the soak itself threw,
///   3 = watchdog: the window layer stopped responding.
int soakIterations() {
  if (!Host.isWindows) return 0;
  final raw = int.tryParse(Platform.environment['AUSHD_WINDOW_SOAK'] ?? '');
  if (raw == null) return 0;
  return raw.clamp(0, 2000);
}

Widget buildWindowSoakApp(int iterations) => _SoakApp(iterations: iterations);

String _reportPath() {
  final configured = Platform.environment['AUSHD_SOAK_REPORT'];
  if (configured != null && configured.isNotEmpty) return configured;
  return '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}soak-report.txt';
}

final class _Report {
  _Report(this.path) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      _sink = file.openSync(mode: FileMode.writeOnly);
    } catch (e) {
      _sink = null;
      // A missing report must not hide the result: the exit code still carries
      // the verdict, and the log sink is opened only when possible.
      stderr.writeln('[soak] cannot open report $path: $e');
    }
  }

  final String path;
  RandomAccessFile? _sink;

  void line(String message) {
    final stamp = DateTime.now().toIso8601String();
    final text = '$stamp $message\n';
    try {
      _sink?.writeStringSync(text);
    } catch (_) {}
    debugPrint(text.trimRight());
  }

  void close() {
    try {
      _sink?.closeSync();
    } catch (_) {}
    _sink = null;
  }
}

class _SoakApp extends StatefulWidget {
  const _SoakApp({required this.iterations});

  final int iterations;

  @override
  State<_SoakApp> createState() => _SoakState();
}

class _SoakState extends State<_SoakApp> with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  final _frames = <int>[];
  final _violations = <String>[];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Keep the raster thread busy: a static tree produces no frames and would
    // hide frame stalls behind a "nothing to draw" window.
    _ticker = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames.add(t.totalSpan.inMicroseconds);
    }
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _settle([int ms = 220]) => Future<void>.delayed(Duration(milliseconds: ms));

  void _expect(String label, bool ok, String detail) {
    if (!ok) _violations.add('$label: $detail');
  }

  String _fmt(Rect r) => '${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}';

  /// Windows rounds the client rect; 2 px is noise, more is drift.
  bool _near(Rect a, Rect b, [double tol = 2]) =>
      (a.width - b.width).abs() <= tol && (a.height - b.height).abs() <= tol;

  /// After a racy probe either rect may win, but a "fullscreen" claim backed by
  /// the baseline rect means the reported state and the window disagree.
  bool _coversAnything(Rect got, Rect? fsRef, Rect base) {
    if (fsRef != null && _near(got, fsRef)) return true;
    return !_near(got, base) && got.width >= base.width && got.height >= base.height;
  }

  Future<void> _run() async {
    final report = _Report(_reportPath());
    final watchdog = Timer(const Duration(seconds: 240), () {
      report.line('[soak] FAIL watchdog: window layer stopped responding after 240s');
      _finish(report, 3);
    });
    var code = 0;
    try {
      report.line('[soak] start iterations=${widget.iterations} exe=${Platform.resolvedExecutable}');

      // Windowed geometry has to be provably smaller than the display, or the
      // "fullscreen covers windowed" invariant cannot hold on a small runner.
      // Start from a deliberately small window instead of trusting the default.
      await NativeWindow.setFullScreen(false);
      await windowManager.setSize(const Size(640, 480));
      await _settle(360);

      _expect('baseline', !(await NativeWindow.isFullScreen()), 'zerk/window still reports fullscreen');

      final base = await windowManager.getBounds();
      final pluginSays = await windowManager.isFullScreen();
      report.line('[soak] baseline windowed bounds=${_fmt(base)}');
      report.line('[soak] diagnostic window_manager.isFullScreen=$pluginSays '
          '(stale by design: the app bypasses the plugin, not a gate)');

      // The frame budget has to be measured on this machine. A GPU-less runner
      // rasterises in WARP, where an absolute p99 measures the environment and
      // not the app, so the gate is relative: one quiet window, then transitions
      // are graded against what this box can already do.
      final idleStart = _frames.length;
      await _settle(1200);
      final idleSpans = _frames.sublist(idleStart)..sort();
      final idleIdx = (idleSpans.length * 0.99).floor();
      final idleP99 = idleSpans.isEmpty
          ? 0
          : idleSpans[idleIdx < idleSpans.length ? idleIdx : idleSpans.length - 1];
      // Median, not p99: the quiet window still contains the first frame after
      // the resize, and on WARP that single frame is hundreds of milliseconds.
      // Grading against a p99 built from 40 samples would let one warmup sample
      // disable the gate entirely.
      final idleMedian = idleSpans.isEmpty ? 0 : idleSpans[idleSpans.length ~/ 2];
      report.line('[soak] idle frames=${idleSpans.length} median=${idleMedian ~/ 1000}ms '
          'p99=${idleP99 ~/ 1000}ms worst=${idleSpans.isEmpty ? 0 : idleSpans.last ~/ 1000}ms');

      final framesBefore = _frames.length;
      Rect? fsRef;
      var driftCount = 0;
      var desyncCount = 0;

      for (var i = 1; i <= widget.iterations; i++) {
        await NativeWindow.setFullScreen(true);
        await _settle();
        final nativeFs = await NativeWindow.isFullScreen();
        final enterBounds = await windowManager.getBounds();
        _expect('i=$i enter', nativeFs, 'zerk/window isFullScreen=false');
        _expect(
          'i=$i enter',
          enterBounds.width >= base.width - 2 && enterBounds.height >= base.height - 2,
          'fullscreen ${_fmt(enterBounds)} does not cover windowed ${_fmt(base)}',
        );
        if (fsRef == null) {
          fsRef = enterBounds;
          report.line('[soak] fullscreen rect=${_fmt(enterBounds)}');
        } else if (!_near(enterBounds, fsRef)) {
          // A rect that changes between rounds is the delayed WM_NCCALCSIZE /
          // missing SWP_FRAMECHANGED signature: the first enter is still wrong
          // and gets corrected by the next resize.
          driftCount++;
          _expect('i=$i enter', false, 'fullscreen drifted ${_fmt(enterBounds)} != ${_fmt(fsRef)}');
        }
        if (!nativeFs) desyncCount++;

        // Every 10th round hammers the entry points the way F11 + the startup
        // path + the OSD key handler can: several toggles without waiting.
        if (i % 10 == 0) {
          final beforeProbe = await NativeWindow.isFullScreen();
          try {
            await Future.wait([
              NativeWindow.toggleFullScreen(),
              NativeWindow.toggleFullScreen(),
              NativeWindow.toggleFullScreen(),
            ]);
            await _settle(420);
            final afterProbe = await NativeWindow.isFullScreen();
            final afterBounds = await windowManager.getBounds();
            report.line('[soak] i=$i concurrent-toggle settled='
                '${afterProbe ? 'fullscreen' : 'windowed'} bounds=${_fmt(afterBounds)}');
            // Three toggles serialise to "not beforeProbe"; a race may land
            // either way, so the winner is not graded - only that the reported
            // state and the geometry still describe the same window.
            if (afterProbe) {
              _expect('i=$i probe', _coversAnything(afterBounds, fsRef, base),
                  'reports fullscreen but bounds ${_fmt(afterBounds)} are neither');
            } else if (!_near(afterBounds, base)) {
              _expect('i=$i probe', false,
                  'reports windowed but bounds ${_fmt(afterBounds)} != baseline ${_fmt(base)}');
            }
            if (afterProbe == beforeProbe) {
              report.line('[soak] i=$i concurrent-toggle note: three toggles did not flip the state '
                  '(racy or lost update) - recorded, not gated here');
            }
          } catch (e) {
            _expect('i=$i probe', false, 'concurrent toggle threw: $e');
          }
          await NativeWindow.setFullScreen(false);
          await _settle();
        }

        await NativeWindow.setFullScreen(false);
        await _settle();
        final nativeBack = await NativeWindow.isFullScreen();
        final exitBounds = await windowManager.getBounds();
        _expect('i=$i exit', !nativeBack, 'zerk/window isFullScreen=true');
        // Exact restore, not "not larger": a window that comes back smaller
        // every round is the placement-accumulation bug leaking state.
        _expect('i=$i exit', _near(exitBounds, base),
            'windowed ${_fmt(exitBounds)} != baseline ${_fmt(base)}');
        if (nativeBack) desyncCount++;

        if (i % 5 == 0) {
          report.line('[soak] i=$i ok frames=${_frames.length - framesBefore} '
              'bounds=${_fmt(exitBounds)}');
        }
      }

      // A leaked fullscreen state is the bug behind "exit to the library and
      // the window stays borderless", so it is a hard failure, not a warning.
      await NativeWindow.setFullScreen(false);
      await _settle(420);
      _expect('final', !(await NativeWindow.isFullScreen()), 'fullscreen state leaked after soak');
      _expect('final', fsRef != null, 'never observed a fullscreen rect');

      if (driftCount > 0) {
        report.line('[soak] fullscreen rect drifted on $driftCount/${widget.iterations} rounds');
      }
      if (desyncCount > 0) {
        report.line('[soak] state/geometry disagreed on $desyncCount/${widget.iterations} rounds');
      }

      final newFrames = _frames.length - framesBefore;
      final expectedFrames = widget.iterations * 2;
      final transitionSpans = _frames.sublist(framesBefore);
      final sorted = [...transitionSpans]..sort();
      final idx = (sorted.length * 0.99).floor();
      final p99 = sorted.isEmpty ? 0 : sorted[idx < sorted.length ? idx : sorted.length - 1];
      report.line('[soak] frames=$newFrames expected>=~$expectedFrames '
          'worst=${sorted.isEmpty ? 0 : sorted.last ~/ 1000}ms p99=${p99 ~/ 1000}ms');
      // 2 toggles per iteration, each settling for 220ms; 48 fps would already
      // be 2 frames per settle window. Anything below that means the raster
      // thread stalled during transitions.
      _expect('frames', newFrames >= widget.iterations, 'raster stalled: $newFrames frames for '
          '${widget.iterations} fullscreen round trips');
      // Only p99 is gated: a single worst-frame spike is what the user sees as
      // jank, but on a GPU-less runner it is also the environment, so it stays
      // reported with its real number. The budget is 3x this box's idle p99
      // with a 50ms floor, so a systematic transition stall still fails and a
      // slow runner does not.
      final budget = idleMedian * 4 > 50000 ? idleMedian * 4 : 50000;
      report.line('[soak] transition frame budget=${budget ~/ 1000}ms '
          '(4x idle median ${idleMedian ~/ 1000}ms, floor 50ms)');
      _expect('frames', p99 <= budget,
          'p99 frame span ${p99 ~/ 1000}ms exceeds the ${budget ~/ 1000}ms budget '
          '(idle median ${idleMedian ~/ 1000}ms)');

      code = _violations.isEmpty ? 0 : 1;
    } catch (e, st) {
      report.line('[soak] FAIL threw: $e\n$st');
      code = 2;
    } finally {
      watchdog.cancel();
      for (final v in _violations.take(40)) {
        report.line('[soak] VIOLATION $v');
      }
      report.line(code == 0
          ? '[soak] PASS iterations=${widget.iterations} frames=${_frames.length}'
          : '[soak] FAIL violations=${_violations.length} code=$code');
      _finish(report, code);
    }
  }

  void _finish(_Report report, int code) {
    if (_done) return;
    _done = true;
    report.close();
    exit(code);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(
        color: const Color(0xFF101014),
        child: AnimatedBuilder(
          animation: _ticker,
          builder: (context, _) => Center(
            child: Text(
              'window soak ${widget.iterations}  frame ${(_frames.length)}',
              style: const TextStyle(color: Color(0xFF7A7A88), fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}
