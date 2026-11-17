import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/playback/mpv/mpv_ipc_protocol.dart';
import 'package:zerk_play/playback/mpv/mpv_player.dart'
    show
        MpvClientMessage,
        MpvEndFile,
        MpvFileLoaded,
        MpvLog,
        MpvPlaybackRestart,
        MpvShutdown;

void main() {
  group('mpv JSON IPC protocol', () {
    test('parses file-loaded and playback-restart events', () {
      final loaded = IpcMessage.parse('{"event":"file-loaded"}');
      expect(loaded?.event, isA<MpvFileLoaded>());
      final restart = IpcMessage.parse('{"event":"playback-restart"}');
      expect(restart?.event, isA<MpvPlaybackRestart>());
    });

    test('parses shutdown event', () {
      final msg = IpcMessage.parse('{"event":"shutdown"}');
      expect(msg?.event, isA<MpvShutdown>());
    });

    test('parses end-file with an error', () {
      final msg = IpcMessage.parse(
          '{"event":"end-file","reason":3,"error":"loading-failed"}');
      final end = msg?.event as MpvEndFile;
      expect(end.reason, 3);
      expect(end.error, 'loading-failed');
    });

    test('end-file success has no error string', () {
      final msg = IpcMessage.parse(
          '{"event":"end-file","reason":0,"error":"success"}');
      final end = msg?.event as MpvEndFile;
      expect(end.error, isNull);
    });

    test('parses property-change with raw value', () {
      final msg = IpcMessage.parse(
          '{"event":"property-change","id":0,"name":"time-pos","data":12.5}');
      expect(msg?.isPropertyChange, isTrue);
      expect(msg?.property, 'time-pos');
      expect(msg?.propertyValue, 12.5);
      expect(msg?.propertyId, 0);
    });

    test('parses track-list property as structured JSON', () {
      final track = {
        'id': 1,
        'type': 'audio',
        'codec': 'aac',
        'selected': true,
        'demux-channel-count': 2,
      };
      final line = jsonEncode({
        'event': 'property-change',
        'id': 9,
        'name': 'track-list',
        'data': [track],
      });
      final msg = IpcMessage.parse(line);
      final data = msg?.propertyValue as List;
      expect(data.first['codec'], 'aac');
      expect(data.first['demux-channel-count'], 2);
    });

    test('maps real client-message event to MpvClientMessage', () {
      // mpv 0.38+ delivers script-message as `client-message` (verified against
      // mpv v0.42.0). No `prefix` field: the script name is not included.
      final line = jsonEncode({
        'event': 'client-message',
        'args': ['zerk-event', 'ready'],
      });
      final msg = IpcMessage.parse(line);
      final client = msg?.event as MpvClientMessage;
      expect(client.args, ['zerk-event', 'ready']);
    });

    test('also accepts legacy message event name', () {
      final msg = IpcMessage.parse(jsonEncode({
        'event': 'message',
        'args': ['zerk-event', 'ready'],
      }));
      expect((msg?.event as MpvClientMessage).args, ['zerk-event', 'ready']);
    });

    test('parses log-message event', () {
      final msg = IpcMessage.parse(
          '{"event":"log-message","prefix":"cplayer","level":"warn","text":"oops\\n"}');
      final log = msg?.event as MpvLog;
      expect(log.text, 'oops');
      expect(log.level, 'warn');
    });

    test('parses command replies by request_id', () {
      final msg = IpcMessage.parse(
          '{"data":null,"error":"success","request_id":7}');
      expect(msg?.replyId, 7);
      expect(msg?.replyError, 'success');
      expect(msg?.replyData, isNull);
    });

    test('ignores malformed and unrelated lines', () {
      expect(IpcMessage.parse(''), isNull);
      expect(IpcMessage.parse('not json'), isNull);
      expect(IpcMessage.parse('{"event":"unknown-event"}'), isNull);
      expect(IpcMessage.parse('{"data":1,"error":"success"}'), isNull);
    });

    test('builds a command with request_id', () {
      final line = ipcCommand(['set_property', 'pause', 'yes'], requestId: 3);
      expect(line.endsWith('\n'), isTrue);
      final decoded = jsonDecode(line.trim()) as Map;
      expect(decoded['command'], ['set_property', 'pause', 'yes']);
      expect(decoded['request_id'], 3);
    });

    test('builds observe_property commands in order', () {
      final observed = ipcObservedProperties;
      expect(observed.first.$1, 'time-pos');
      expect(observed.last.$1, 'container-fps');
      final line = ipcObserve(2, observed[2].$1);
      final decoded = jsonDecode(line.trim()) as Map;
      expect(decoded['command'], ['observe_property', 2, 'pause']);
    });
  });
}
