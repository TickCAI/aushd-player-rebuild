import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_settings.dart';

/// Remembers which render path was live when a playback session died.
///
/// The guard used to rewrite the user's settings on every crash: the first
/// crash moved an untouched install to Vulkan, the second moved it to WGL
/// OpenGL with software decoding, and nothing ever moved it back. The two
/// crashes that were actually caught then turned out to have happened on
/// (gpu-next, Vulkan) and on (gpu, OpenGL) - both ends of that ladder. So the
/// ladder was recording the history of our guesses in the user's profile, not
/// the cause.
///
/// It now only remembers. The mode fingerprint that was live when the process
/// died is stored, the next launch steers around exactly that combination, and
/// after [cleanToForget] sessions that end normally the memory is dropped. A
/// crash no longer edits what the user chose.
abstract final class RenderGuard {
  static const _key = 'render.memory.v1';

  /// The retired 1.0.5 guard's key. It recorded how many times it had stepped
  /// the settings down a ladder, and 1.0.9 shipped installs whose backend was
  /// rewritten by it (9 steps deep on the machine that produced the dumps).
  /// Those writes are indistinguishable from a manual pick, so a poisoned
  /// install needs this key as the evidence that the value was never chosen.
  static const _legacyKey = 'flutter.render.guard.v1';

  /// Give the native VO teardown time to finish. A crash in
  /// `vo/gpu/win32 uninit` happens after the user pressed back but before mpv
  /// is gone, so clearing the marker immediately would hide that failure.
  static const _teardownGrace = Duration(seconds: 20);

  /// Sessions that end normally before an avoided mode is forgotten.
  static const cleanToForget = 3;

  /// Windows render backends, in the order this project tries them.
  static const apiLadder = ['d3d11', 'vulkan', 'opengl'];

  static Timer? _clearTimer;
  static String? _avoid;
  static String? _lastMode;
  static int _clean = 0;

  /// The mode fingerprint to steer around for this launch, when the previous
  /// launch died during playback.
  static String? get avoid => _avoid;

  /// Sessions that ended without leaving the marker behind.
  static int get cleanSessions => _clean;

  /// Identifies a render path closely enough to recognise it again.
  static String fingerprint({
    required String vo,
    required String api,
    required String gpuContext,
    required String hwdec,
  }) =>
      'vo=$vo api=$api context=$gpuContext hwdec=$hwdec';

  /// The backend to try after [api] died. Wraps around the ladder so a crash on
  /// the last rung still produces a different path.
  static String nextApi(String api) {
    final i = apiLadder.indexOf(api);
    return apiLadder[(i < 0 ? 0 : i + 1) % apiLadder.length];
  }

  /// Corrects the default of installs that never picked a backend themselves.
  ///
  /// 1.0.5 wrote the untouched default out as Vulkan. That was the wrong
  /// direction on this hardware: the recorded D3D11 death happened while the
  /// driver was tearing a swapchain down, and Vulkan goes through the same
  /// `amdxx64` user-mode driver. The (gpu, d3d11, blt presentation) path is the
  /// one that has not produced a dump yet, so that is where an untouched
  /// install belongs. A manual pick is never overwritten.
  static PlayerSettings migrateDefault(PlayerSettings current) {
    if (!current.gpuApiAuto || current.safeGpuApi == 'd3d11') return current;
    return current.copyWith(gpuApi: 'd3d11', videoOutput: 'gpu', hwdec: 'd3d11va');
  }

  /// Run once at startup, before any player is created.
  static Future<void> recoverOnStartup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        try {
          final state = jsonDecode(raw) as Map<String, dynamic>;
          final clean = state['clean'];
          _clean = clean is int ? clean : 0;
          final mode = state['mode'];
          final ended = state['ending'] == true;
          _avoid = ended && mode is String && mode.isNotEmpty ? mode : null;
          if (_avoid != null) {
            debugPrint('[render-guard] the previous run died while rendering $_avoid; '
                'this session avoids that combination (settings untouched)');
          } else if (_clean > 0) {
            debugPrint('[render-guard] $_clean clean session(s) so far');
          }
        } catch (_) {}
      }
      final current = await PlayerSettings.load();
      var migrated = migrateDefault(current);
      // The retired guard's ladder wrote our own crashes into the profile and
      // then looked exactly like a manual pick. Rescue that install once, using
      // the retired key as the evidence, then drop the key so that a pick made
      // in the UI is never overwritten again.
      var legacySteps = 0;
      final legacyRaw = prefs.getString(_legacyKey);
      if (legacyRaw != null) {
        try {
          final legacy = jsonDecode(legacyRaw) as Map<String, dynamic>;
          final steps = legacy['steps'];
          legacySteps = steps is int ? steps : 0;
        } catch (_) {}
      }
      if (legacySteps > 0 &&
          (current.safeGpuApi != 'd3d11' ||
              current.videoOutput != 'gpu' ||
              current.hwdec != 'd3d11va')) {
        migrated = migrated.copyWith(gpuApi: 'd3d11', videoOutput: 'gpu', hwdec: 'd3d11va');
        debugPrint('[render-guard] the retired guard had stepped this install down '
            '$legacySteps time(s), ending at ${current.safeGpuApi}/'
            '${current.videoOutput}/${current.hwdec}; moving it to d3d11/gpu/d3d11va once');
        await prefs.remove(_legacyKey);
      }
      if (!identical(migrated, current)) {
        await migrated.save();
        debugPrint('[render-guard] render path is now '
            '${migrated.safeGpuApi}/${migrated.videoOutput}/${migrated.hwdec}');
      }
      // Clears the "still running" flag; the avoided mode above stays loaded.
      await _write(prefs, ending: false);
    } catch (e) {
      debugPrint('[render-guard] recovery failed: $e');
    }
  }

  /// Playback session is starting. Records the mode that is about to be used so
  /// that a native fault after this point can be attributed to it. Cancels any
  /// pending clear so a quick play -> stop -> play cannot erase the marker
  /// mid-session.
  static Future<void> markPlaybackStarted({required String mode}) async {
    _clearTimer?.cancel();
    _clearTimer = null;
    _lastMode = mode;
    try {
      await _write(await SharedPreferences.getInstance(), ending: true, mode: mode);
      debugPrint('[render-guard] session marked with $mode');
    } catch (e) {
      debugPrint('[render-guard] could not persist the playback marker: $e');
    }
  }

  /// A launch failed before playback began: a GPU context mpv could not
  /// initialize, a missing ICD, a video host that never answered. That is a
  /// real answer about this render path, so remember it instead of stepping the
  /// user's settings down a ladder and leaving them there.
  static Future<void> noteLaunchFailure() async {
    final mode = _lastMode;
    if (mode == null) return;
    _avoid = mode;
    debugPrint('[render-guard] the launch failed on $mode; avoiding it next time');
    try {
      await _write(await SharedPreferences.getInstance(), ending: true, mode: mode);
    } catch (e) {
      debugPrint('[render-guard] could not record the failed mode: $e');
    }
  }

  /// Playback ended. Keep the marker for [_teardownGrace] so a fault during VO
  /// teardown is still attributed to this session.
  static void markPlaybackFinished() {
    _clearTimer?.cancel();
    _clearTimer = Timer(_teardownGrace, () async {
      _clearTimer = null;
      await finishClean();
    });
  }

  /// Clean application exit, or a session that ended normally.
  static Future<void> finishClean() async {
    _clearTimer?.cancel();
    _clearTimer = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      _clean += 1;
      if (_clean >= cleanToForget) {
        _clean = 0;
        if (_avoid != null) {
          debugPrint('[render-guard] $cleanToForget clean sessions; forgetting $_avoid');
          _avoid = null;
        }
      }
      await _write(prefs, ending: false);
    } catch (e) {
      debugPrint('[render-guard] could not clear the playback marker: $e');
    }
  }

  static Future<void> _write(SharedPreferences prefs, {required bool ending, String? mode}) =>
      prefs.setString(
        _key,
        jsonEncode({
          'ending': ending,
          'mode': ending ? mode : null,
          'clean': _clean,
          'at': DateTime.now().toIso8601String(),
        }),
      );
}
