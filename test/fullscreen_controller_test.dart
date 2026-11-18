import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/core/windows/fullscreen_controller.dart';

/// The window layer has no widget to pump and no golden to compare; the thing
/// that actually broke in 1.0.5-1.0.9 was the *ordering* of fullscreen
/// requests. So these tests drive the controller against a fake native side
/// and assert the queue, the authority and the counters.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zerk/window');
  var native = false;
  var setCalls = 0;
  var reads = 0;
  var nativeRejects = false;
  var nativeThrows = false;

  final controller = FullscreenController.instance;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    native = false;
    setCalls = 0;
    reads = 0;
    nativeRejects = false;
    nativeThrows = false;
    controller.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'isFullScreen':
          reads++;
          return native;
        case 'setFullScreen':
          setCalls++;
          final want = call.arguments as bool;
          if (nativeThrows) throw PlatformException(code: 'failed');
          if (nativeRejects) return false;
          native = want;
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sync adopts what the window really is', () async {
    native = true;
    await controller.sync();
    expect(controller.phase.value, FullscreenPhase.fullscreen);
    expect(controller.isFullscreen, isTrue);
    expect(setCalls, 0);
  });

  test('a request that is already satisfied does not resize the window', () async {
    native = true;
    await controller.sync();
    setCalls = 0;
    expect(await controller.setFullScreen(true), isTrue);
    expect(setCalls, 0, reason: 'no-op request must not touch the window');
    expect(controller.transitions, 0);
  });

  test('a successful transition leaves the phase matching the native state', () async {
    expect(await controller.setFullScreen(true), isTrue);
    expect(native, isTrue);
    expect(controller.phase.value, FullscreenPhase.fullscreen);
    expect(controller.transitions, 1);
    expect(controller.failures, 0);

    expect(await controller.setFullScreen(false), isTrue);
    expect(native, isFalse);
    expect(controller.phase.value, FullscreenPhase.windowed);
    expect(controller.transitions, 2);
  });

  test('the native side is the authority when it refuses', () async {
    nativeRejects = true;
    expect(await controller.setFullScreen(true), isFalse);
    expect(controller.phase.value, FullscreenPhase.windowed,
        reason: 'a rejected request must not report fullscreen');
    expect(controller.isFullscreen, isFalse);
    expect(controller.failures, 1);
    expect(native, isFalse);
  });

  test('a throwing native call is a failure, not an exception', () async {
    nativeThrows = true;
    expect(await controller.setFullScreen(true), isFalse);
    expect(controller.phase.value, FullscreenPhase.windowed);
    expect(controller.failures, 1);
  });

  test('three overlapping toggles are serialised, not interleaved', () async {
    // The old toggle did isFullScreen() then setFullScreen(!fs) with no
    // serialisation: two overlapping calls both read the same state and both
    // asked for the same target, so one transition was lost. Serialised, three
    // toggles from windowed must be three real transitions ending fullscreen.
    final results = await Future.wait([
      controller.toggleFullScreen(),
      controller.toggleFullScreen(),
      controller.toggleFullScreen(),
    ]);
    expect(results, everyElement(isTrue));
    expect(controller.transitions, 3);
    expect(controller.failures, 0);
    expect(controller.queued, 0);
    expect(native, isTrue);
    expect(controller.phase.value, FullscreenPhase.fullscreen);
  });

  test('a queued request sees the state the previous one produced', () async {
    final first = controller.setFullScreen(true);
    final second = controller.toggleFullScreen();
    expect(await first, isTrue);
    // The toggle runs after the enter, so it sees fullscreen and exits.
    expect(await second, isTrue);
    expect(native, isFalse);
    expect(controller.transitions, 2);
    expect(controller.failures, 0);
  });
}
