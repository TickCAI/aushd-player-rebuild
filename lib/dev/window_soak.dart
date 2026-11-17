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
///  * `zerk/window` state must agree with `window_manager` after every toggle;
///  * fullscreen bounds must cover the windowed bounds and shrink back;
///  * concurrent toggles must not wedge the window layer;
///  * the last toggle must leave the app windowed (no leaked fullscreen state);
///  * the raster thread must keep producing frames during the transitions.
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

  Future<void> _run() async {
    final report = _Report(_reportPath());
    final watchdog = Timer(const Duration(seconds: 240), () {
      report.line('[soak] FAIL watchdog: window layer stopped responding after 240s');
      _finish(report, 3);
    });
    var code = 0;
    try {
      report.line('[soak] start iterations=${widget.iterations} exe=${Platform.resolvedExecutable}');

      await NativeWindow.setFullScreen(false);
      await _settle(320);

      final nativeWindowed = await NativeWindow.isFullScreen();
      final pluginWindowed = await windowManager.isFullScreen();
      _expect('baseline', !nativeWindowed, 'zerk/window still reports fullscreen');
      _expect('baseline', !pluginWindowed, 'window_manager still reports fullscreen');

      final base = await windowManager.getBounds();
      report.line('[soak] baseline windowed bounds=${base.width.toStringAsFixed(0)}x'
          '${base.height.toStringAsFixed(0)}');

      final framesBefore = _frames.length;

      for (var i = 1; i <= widget.iterations; i++) {
        await NativeWindow.setFullScreen(true);
        await _settle();
        final nativeFs = await NativeWindow.isFullScreen();
        final pluginFs = await windowManager.isFullScreen();
        final enterBounds = await windowManager.getBounds();
        _expect('i=$i enter', nativeFs, 'zerk/window isFullScreen=false');
        _expect('i=$i enter', pluginFs, 'window_manager isFullScreen=false');
        _expect(
          'i=$i enter',
          enterBounds.width >= base.width - 2 && enterBounds.height >= base.height - 2,
          'fullscreen ${enterBounds.width.toStringAsFixed(0)}x${enterBounds.height.toStringAsFixed(0)}'
              ' smaller than windowed ${base.width.toStringAsFixed(0)}x${base.height.toStringAsFixed(0)}',
        );

        // Every 10th round hammers the entry points the way F11 + the startup
        // path + the OSD key handler can: several toggles without waiting.
        if (i % 10 == 0) {
          try {
            await Future.wait([
              NativeWindow.toggleFullScreen(),
              NativeWindow.toggleFullScreen(),
              NativeWindow.toggleFullScreen(),
            ]);
            await _settle(420);
            final probed = await NativeWindow.isFullScreen();
            report.line('[soak] i=$i concurrent-toggle settled=${probed ? 'fullscreen' : 'windowed'}');
          } catch (e) {
            _expect('i=$i probe', false, 'concurrent toggle threw: $e');
          }
          await NativeWindow.setFullScreen(false);
          await _settle();
        }

        await NativeWindow.setFullScreen(false);
        await _settle();
        final nativeBack = await NativeWindow.isFullScreen();
        final pluginBack = await windowManager.isFullScreen();
        final exitBounds = await windowManager.getBounds();
        _expect('i=$i exit', !nativeBack, 'zerk/window isFullScreen=true');
        _expect('i=$i exit', !pluginBack, 'window_manager isFullScreen=true');
        _expect(
          'i=$i exit',
          exitBounds.width <= base.width + 2 && exitBounds.height <= base.height + 2,
          'windowed ${exitBounds.width.toStringAsFixed(0)}x${exitBounds.height.toStringAsFixed(0)}'
              ' larger than baseline ${base.width.toStringAsFixed(0)}x${base.height.toStringAsFixed(0)}',
        );

        if (i % 5 == 0) {
          report.line('[soak] i=$i ok frames=${_frames.length - framesBefore} '
              'bounds=${exitBounds.width.toStringAsFixed(0)}x${exitBounds.height.toStringAsFixed(0)}');
        }
      }

      // A leaked fullscreen state is the bug behind "exit to the library and
      // the window stays borderless", so it is a hard failure, not a warning.
      await NativeWindow.setFullScreen(false);
      await _settle(420);
      _expect('final', !(await NativeWindow.isFullScreen()), 'fullscreen state leaked after soak');

      final newFrames = _frames.length - framesBefore;
      final expectedFrames = widget.iterations * 2;
      final sorted = [..._frames]..sort();
      final idx = (sorted.length * 0.99).floor();
      final p99 = sorted.isEmpty ? 0 : sorted[idx < sorted.length ? idx : sorted.length - 1];
      report.line('[soak] frames=$newFrames expected>=~$expectedFrames '
          'worst=${sorted.isEmpty ? 0 : sorted.last ~/ 1000}ms p99=${p99 ~/ 1000}ms');
      // 2 toggles per iteration, each settling for 220ms; 48 fps would already
      // be 2 frames per settle window. Anything below that means the raster
      // thread stalled during transitions.
      _expect('frames', newFrames >= widget.iterations, 'raster stalled: $newFrames frames for '
          '${widget.iterations} fullscreen round trips');
      _expect('frames', p99 < 50000, 'p99 frame span ${p99 ~/ 1000}ms exceeds 50ms budget');

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
