import 'dart:async';

import 'package:flutter/foundation.dart';

import '../log/app_log.dart';
import 'native_window.dart';

/// Where the window is in the fullscreen handshake.
///
/// `entering` / `exiting` are real states, not decoration: during them the
/// window is mid-`SetWindowPos` with a changed frame style, and anything that
/// resizes, re-shows or re-lays-out the video host in that window is racing the
/// compositor.
enum FullscreenPhase { windowed, entering, fullscreen, exiting }

/// The single authority for fullscreen transitions.
///
/// Before this existed, three entry points (the boot-time fullscreen call, the
/// F11 shortcut and the mpv OSD command) each did
/// `isFullScreen()` then `setFullScreen(!fs)` with no serialisation. Two of them
/// overlapping meant two `SetWindowPos` rounds on one HWND, with the second one
/// computed from a state the first had not finished applying.
///
/// Two rules keep it honest:
///  * requests are serialised through one queue, so a transition never overlaps
///    another transition;
///  * the native side is the authority afterwards, so a rejected or timed-out
///    transition leaves the controller reporting what really happened instead of
///    what was asked for.
final class FullscreenController {
  FullscreenController._();

  static final FullscreenController instance = FullscreenController._();

  static const Duration _ipcTimeout = Duration(seconds: 3);

  final ValueNotifier<FullscreenPhase> phase = ValueNotifier(FullscreenPhase.windowed);

  Future<Object?> _tail = Future<Object?>.value();

  int _transitions = 0;
  int _failures = 0;
  int _queued = 0;

  bool get isFullscreen =>
      phase.value == FullscreenPhase.fullscreen || phase.value == FullscreenPhase.entering;

  bool get isTransitioning =>
      phase.value == FullscreenPhase.entering || phase.value == FullscreenPhase.exiting;

  /// Transitions that actually ran, failures, and requests still waiting.
  int get transitions => _transitions;

  int get failures => _failures;

  int get queued => _queued;

  /// Adopts the native state without transitioning. Used once at startup: the
  /// window may already be fullscreen from the previous session.
  Future<void> sync() async {
    final actual = await _readNative();
    phase.value = actual ? FullscreenPhase.fullscreen : FullscreenPhase.windowed;
  }

  Future<bool> setFullScreen(bool target) => _enqueue(() => target);

  Future<bool> toggleFullScreen() => _enqueue(() async => !(await _readNative()));

  Future<bool> _enqueue(Future<bool> Function() decide) {
    _queued++;
    final completer = Completer<bool>();
    _tail = _tail.then((_) async {
      _queued--;
      try {
        final target = await decide();
        if (await _readNative() == target) {
          // Already there. Report success without touching the window; a no-op
          // toggle must not resize, because the resize is the expensive part.
          phase.value = target ? FullscreenPhase.fullscreen : FullscreenPhase.windowed;
          completer.complete(true);
          return null;
        }
        completer.complete(await _apply(target));
      } catch (error, stack) {
        _failures++;
        AppLog.write('[fullscreen] request failed: $error\n$stack');
        if (!completer.isCompleted) completer.complete(false);
      }
      return null;
    });
    return completer.future;
  }

  Future<bool> _apply(bool target) async {
    final previous = phase.value;
    phase.value = target ? FullscreenPhase.entering : FullscreenPhase.exiting;
    _transitions++;
    var applied = false;
    try {
      applied = await NativeWindow.setFullScreen(target).timeout(_ipcTimeout);
    } on TimeoutException {
      applied = false;
    } catch (error) {
      applied = false;
      AppLog.write('[fullscreen] set fullscreen threw: $error');
    }
    final actual = await _readNative();
    // The native state wins. Trusting `applied` alone is what let a failed
    // monitor lookup leave Dart convinced the window was fullscreen while mpv
    // and the layout code acted on a different geometry.
    phase.value = actual ? FullscreenPhase.fullscreen : FullscreenPhase.windowed;
    if (!applied || actual != target) {
      _failures++;
      AppLog.write(
        '[fullscreen] target=$target applied=$applied actual=$actual previous=$previous',
      );
      return false;
    }
    AppLog.mark('[fullscreen] ${target ? 'enter' : 'exit'} ok');
    return true;
  }

  Future<bool> _readNative() async {
    try {
      return await NativeWindow.isFullScreen().timeout(_ipcTimeout);
    } catch (_) {
      // Fall back to the belief we last observed rather than inventing a value.
      return phase.value == FullscreenPhase.fullscreen;
    }
  }
}
