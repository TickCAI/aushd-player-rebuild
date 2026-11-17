// Temporary regression: reproduce the backend race where load-script is sent
// immediately after create() (before the pipe connects). It must not be dropped.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zerk_play/playback/mpv/mpv_ipc_player.dart';
import 'package:zerk_play/playback/mpv/mpv_player.dart' show MpvClientMessage;

void main() {
  test('load-script right after create() is not dropped; OSD reports ready', () async {
    final mpvExe = Platform.environment['MPV_EXE'];
    final luaPath = Platform.environment['OSD_LUA'];
    if (mpvExe == null || luaPath == null) {
      // Optional end-to-end test: needs a real mpv.exe + OSD script. Skipped on
      // CI where those binaries are not present.
      return;
    }

    final player = MpvIpcPlayer.create(
      executable: mpvExe,
      logLevel: 'info',
      options: const {'idle': 'yes', 'vo': 'null', 'ao': 'null', 'force-window': 'no'},
    );

    final ready = Completer<bool>();
    final sub = player.events.listen((e) {
      if (e is MpvClientMessage &&
          e.args.length >= 2 &&
          e.args[0] == 'zerk-event' &&
          e.args[1] == 'ready') {
        if (!ready.isCompleted) ready.complete(true);
      }
    });

    // This is the exact call the backend makes right after create(), while
    // _start() is still awaiting Process.start / pipe connect.
    player.command(['load-script', luaPath]);

    final got = await ready.future.timeout(const Duration(seconds: 8), onTimeout: () => false);
    // ignore: avoid_print
    print('READY=$got');
    expect(got, isTrue, reason: 'load-script queued before pipe connect must still load and OSD report ready');

    await sub.cancel();
    player.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }, timeout: const Timeout(Duration(seconds: 20)));
}
