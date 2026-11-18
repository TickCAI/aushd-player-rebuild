import 'dart:ui' show Rect;

import 'package:flutter/services.dart';

import '../host.dart';

final class DisplayHdrStatus {
  const DisplayHdrStatus({this.supported = false, this.enabled = false});

  final bool supported;

  final bool enabled;
}

/// A read-only snapshot of the window layer, used by the soak harness and by
/// support logs. It exists so a cloud run can assert *rates* (one resize per
/// toggle, not four) instead of only the end state.
final class WindowDiag {
  const WindowDiag({
    required this.fullscreen,
    required this.style,
    required this.windowRect,
    required this.clientRect,
    required this.monitorRect,
    required this.wmSize,
    required this.minimizedResize,
    required this.moveWindows,
    required this.coalesced,
    required this.mismatch,
    required this.setWindowPosFailures,
  });

  final bool fullscreen;
  final int style;
  final Rect windowRect;
  final Rect clientRect;
  final Rect monitorRect;
  final int wmSize;
  final int minimizedResize;
  final int moveWindows;
  final int coalesced;
  final int mismatch;
  final int setWindowPosFailures;

  static Rect _rect(Object? value) {
    if (value is List && value.length == 4) {
      final l = (value[0] as num).toDouble();
      final t = (value[1] as num).toDouble();
      final r = (value[2] as num).toDouble();
      final b = (value[3] as num).toDouble();
      return Rect.fromLTRB(l, t, r, b);
    }
    return Rect.zero;
  }

  static WindowDiag fromMap(Map<Object?, Object?> m) {
    int asInt(String key) => (m[key] as num?)?.toInt() ?? 0;
    return WindowDiag(
      fullscreen: m['fullscreen'] as bool? ?? false,
      style: asInt('style'),
      windowRect: _rect(m['windowRect']),
      clientRect: _rect(m['clientRect']),
      monitorRect: _rect(m['monitorRect']),
      wmSize: asInt('wmSize'),
      minimizedResize: asInt('minimizedResize'),
      moveWindows: asInt('moveWindows'),
      coalesced: asInt('coalesced'),
      mismatch: asInt('mismatch'),
      setWindowPosFailures: asInt('setWindowPosFailures'),
    );
  }

  @override
  String toString() =>
      'WindowDiag(fullscreen=$fullscreen style=0x${style.toRadixString(16)} '
      'window=$windowRect client=$clientRect monitor=$monitorRect '
      'wmSize=$wmSize minimized=$minimizedResize moves=$moveWindows '
      'coalesced=$coalesced mismatch=$mismatch setWindowPosFail=$setWindowPosFailures)';
}

abstract final class NativeWindow {
  static const _channel = MethodChannel('zerk/window');

  static Future<bool> isFullScreen() async {
    return Host.isDesktop && (await _channel.invokeMethod<bool>('isFullScreen') ?? false);
  }

  /// Applies the requested state and reports whether it actually took effect.
  ///
  /// The native side used to return nothing and report success unconditionally,
  /// so a failed monitor lookup left Dart, mpv and the layout code each holding a
  /// different idea of the window state.
  static Future<bool> setFullScreen(bool fullscreen) async {
    if (!Host.isDesktop) return false;
    try {
      return await _channel.invokeMethod<bool>('setFullScreen', fullscreen) ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<WindowDiag?> diag() async {
    if (!Host.isDesktop) return null;
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('diag');
      return m == null ? null : WindowDiag.fromMap(m);
    } on PlatformException {
      return null;
    }
  }

  static Future<DisplayHdrStatus> hdrStatus() async {
    if (!Host.isWindows) return const DisplayHdrStatus();
    try {
      final m = await _channel.invokeMapMethod<String, bool>('hdrStatus');
      return DisplayHdrStatus(supported: m?['supported'] ?? false, enabled: m?['enabled'] ?? false);
    } on PlatformException {
      return const DisplayHdrStatus();
    }
  }

  static Future<bool> setHdr(bool enabled) async {
    if (!Host.isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('setHdr', enabled) ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> waitForHdr(bool enabled, {Duration timeout = const Duration(seconds: 4)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if ((await hdrStatus()).enabled == enabled) return true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }
}
