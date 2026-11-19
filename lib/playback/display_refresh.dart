import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import 'kept_display.dart';

final class DisplayRefreshMatcher {
  static String? _device;

  /// Display mode switching is available again, but nothing reaches it unless
  /// the user turns it on: `PlayerSettings.matchRefreshRate` defaults to false
  /// and `playback_session.dart` is the only caller.
  ///
  /// It was hard-disabled while the 2026-11-18 crashes were being isolated: five
  /// dumps, one per attempt, dying on all three render backends - d3d11, vulkan
  /// and opengl - so the backend was never the variable. What all five sessions
  /// had in common was a mode change: `ChangeDisplaySettingsEx` to 75 Hz when the
  /// file loaded, and back to 120 Hz on the way out (`[display] restoring the
  /// desktop refresh rate`, 24 s after the player was already gone); the crash
  /// five seconds later landed inside `flutter_windows.dll`, i.e. in ANGLE's
  /// surface, not in mpv's. With the switch off, ten fullscreen round trips on a
  /// 4K HDR10 clip passed, which is what identified the mode change as the thing
  /// that invalidates every surface the driver is holding.
  ///
  /// So it stays opt-in. The switch is kept as a kill switch rather than deleted
  /// because a machine with fewer display outputs may be fine with it, and this
  /// way the decision is one constant away instead of a revert.
  static const bool modeSwitchingEnabled = true;

  double? matchFrameRate(double fps, {int? hwnd}) {
    if (!Platform.isWindows || fps < 10 || fps > 121) return null;
    if (!modeSwitchingEnabled) {
      debugPrint('[refresh] mode switching is disabled in this build; '
          'staying at the desktop rate for ${fps.toStringAsFixed(3)} fps video');
      return null;
    }
    return using((arena) {
      final device = _monitorDevice(arena, hwnd ?? GetForegroundWindow());
      if (device == null) return null;
      final devName = device.toNativeUtf16(allocator: arena);

      final current = arena<DEVMODE>()..ref.dmSize = sizeOf<DEVMODE>();
      if (EnumDisplaySettings(devName, ENUM_CURRENT_SETTINGS, current) == 0) return null;
      final w = current.ref.dmPelsWidth, h = current.ref.dmPelsHeight;
      final bpp = current.ref.dmBitsPerPel;

      final currentHz = _actualHz(current.ref.dmDisplayFrequency);
      debugPrint('[refresh] ${fps.toStringAsFixed(3)} fps video on $device, now ${w}x$h @ ${currentHz.toStringAsFixed(3)} Hz');
      if (_isMultiple(currentHz, fps)) {
        debugPrint('[refresh] current rate already fits');
        return null;
      }

      final mode = arena<DEVMODE>()..ref.dmSize = sizeOf<DEVMODE>();
      int? best;
      for (var i = 0; EnumDisplaySettings(devName, i, mode) != 0; i++) {
        final m = mode.ref;
        if (m.dmPelsWidth != w || m.dmPelsHeight != h || m.dmBitsPerPel != bpp) continue;
        final hz = m.dmDisplayFrequency;
        if (!_isMultiple(_actualHz(hz), fps)) continue;
        if (best == null || hz < best) best = hz;
      }
      if (best == null) {
        debugPrint('[refresh] no mode matches ${fps.toStringAsFixed(3)} fps at ${w}x$h');
        return null;
      }

      current.ref
        ..dmDisplayFrequency = best
        ..dmFields = DM_DISPLAYFREQUENCY | DM_PELSWIDTH | DM_PELSHEIGHT;
      debugPrint('[refresh] switching ${w}x$h from ${currentHz.toStringAsFixed(3)} Hz '
          'to $best Hz for ${fps.toStringAsFixed(3)} fps - this is the path that '
          'crashed on 2026-11-18; it stays off by default for that reason');
      final rc = ChangeDisplaySettingsEx(devName, current, NULL, CDS_FULLSCREEN, nullptr);
      if (rc != DISP_CHANGE_SUCCESSFUL) {
        debugPrint('[refresh] ChangeDisplaySettingsEx($best Hz) failed: $rc');
        return null;
      }
      debugPrint('[refresh] switched to $best Hz');
      _device = device;
      KeptDisplay.restoreRefresh = null;
      return _actualHz(best);
    });
  }

  void restore() => _restore();

  void keep() {
    if (_device == null) return;
    debugPrint('[refresh] keeping $_device in its playback mode');
    KeptDisplay.restoreRefresh = _restore;
  }

  static void _restore() {
    final device = _device;
    if (device == null) return;
    _device = null;
    KeptDisplay.restoreRefresh = null;
    if (!modeSwitchingEnabled) {
      debugPrint('[refresh] restore skipped (mode switching disabled in this build)');
      return;
    }
    final rc = using((arena) => ChangeDisplaySettingsEx(device.toNativeUtf16(allocator: arena), nullptr, NULL, 0, nullptr));
    debugPrint('[refresh] restored $device to its desktop mode (rc $rc)');
  }

  static double _actualHz(int hz) =>
      const {23, 29, 47, 59, 71, 119, 143}.contains(hz) ? (hz + 1) * 1000 / 1001 : hz.toDouble();

  static bool _isMultiple(double hz, double fps) {
    for (var k = 1; k <= 6; k++) {
      if ((hz - fps * k).abs() < 0.02 * k) return true;
    }
    return false;
  }

  static String? _monitorDevice(Arena arena, int hwnd) {
    final monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    final info = arena<MONITORINFOEX>()..ref.monitorInfo.cbSize = sizeOf<MONITORINFOEX>();
    if (GetMonitorInfo(monitor, info.cast()) == 0) return null;
    return info.ref.szDevice;
  }
}
