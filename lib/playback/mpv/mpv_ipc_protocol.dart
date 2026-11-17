import 'dart:convert';

import 'mpv_player.dart'
    show
        MpvClientMessage,
        MpvEndFile,
        MpvEvent,
        MpvFileLoaded,
        MpvLog,
        MpvPlaybackRestart,
        MpvShutdown;

/// The result of parsing one line of mpv JSON IPC output.
///
/// Kept independent of the transport so the protocol can be unit-tested on
/// any platform without a named pipe or a real mpv process.
final class IpcMessage {
  const IpcMessage._({
    this.event,
    this.property,
    this.propertyValue,
    this.propertyId,
    this.replyId,
    this.replyError,
    this.replyData,
  });

  /// A high-level player event to forward to MpvBackend.
  final MpvEvent? event;

  /// A `property-change` notification: name and raw JSON value.
  final String? property;
  final Object? propertyValue;
  final int? propertyId;

  /// A reply to a command that carried a request_id.
  final int? replyId;
  final String? replyError;
  final Object? replyData;

  bool get isPropertyChange => property != null;

  /// Parses one JSON line emitted by mpv's `--input-ipc-server`.
  ///
  /// Returns null for lines that carry no actionable message (e.g. replies
  /// without a request_id). Never throws on malformed input so a single bad
  /// line cannot tear down the read loop.
  static IpcMessage? parse(String line) {
    if (line.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = decoded.cast<String, Object?>();

    final event = map['event'];
    if (event is String) {
      return _parseEvent(map, event);
    }

    final replyId = map['request_id'];
    if (replyId is num) {
      final error = map['error'];
      return IpcMessage._(
        replyId: replyId.toInt(),
        replyError: error is String ? error : null,
        replyData: map['data'],
      );
    }
    return null;
  }

  static IpcMessage? _parseEvent(Map<String, Object?> map, String event) {
    switch (event) {
      case 'file-loaded':
        return const IpcMessage._(event: MpvFileLoaded());
      case 'playback-restart':
        return const IpcMessage._(event: MpvPlaybackRestart());
      case 'shutdown':
        return const IpcMessage._(event: MpvShutdown());
      case 'end-file':
        final reason = (map['reason'] as num?)?.toInt() ?? 2;
        final err = map['error'] as String?;
        return IpcMessage._(
            event: MpvEndFile(reason, err != null && err != 'success' ? err : null));
      case 'property-change':
        final name = map['name'] as String?;
        if (name == null) return null;
        return IpcMessage._(
          property: name,
          propertyValue: map['data'],
          propertyId: (map['id'] as num?)?.toInt(),
        );
      case 'message':
        // `script-message` from a Lua script arrives as event "message" with
        // the script id and the argument array in `args`.
        final args = map['args'];
        if (args is List) {
          return IpcMessage._(
            event: MpvClientMessage([
              for (final a in args) a.toString(),
            ]),
          );
        }
        return null;
      case 'log-message':
        final text = map['text'] as String? ?? '';
        final prefix = map['prefix'] as String? ?? 'ipc';
        final level = map['level'] as String? ?? 'info';
        return IpcMessage._(event: MpvLog(prefix, level, text.trimRight()));
      default:
        return null;
    }
  }
}

/// The properties we observe at startup, in the exact order used as IPC ids.
/// Mirrors MpvPlayer._observed so the state mapping stays identical.
const ipcObservedProperties = <(String, String)>[
  ('time-pos', 'double'),
  ('duration', 'double'),
  ('pause', 'flag'),
  ('paused-for-cache', 'flag'),
  ('seeking', 'flag'),
  ('cache-buffering-state', 'int'),
  ('demuxer-cache-time', 'double'),
  ('eof-reached', 'flag'),
  ('idle-active', 'flag'),
  ('track-list', 'node'),
  ('volume', 'double'),
  ('mute', 'flag'),
  ('video-params', 'node'),
  ('hwdec-current', 'string'),
  ('container-fps', 'double'),
];

/// Builds a JSON IPC command line. `request_id` is assigned by the caller.
String ipcCommand(List<Object> args, {int? requestId}) {
  final map = <String, Object?>{
    'command': args,
    'request_id': ?requestId,
  };
  return '${jsonEncode(map)}\n';
}

/// Builds the `observe_property` command. The id must be a JSON number, not
/// a string, or mpv rejects the observation silently.
String ipcObserve(int id, String name) =>
    ipcCommand(['observe_property', id, name]);
