import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hot-reload configuration delivered by the distribution service.
///
/// This is *configuration/resource* hot reload (row order, feature flags,
/// announcements, danmaku sources, OpenList presets) — never Dart code reload.
/// A build with no distribution service configured simply keeps the defaults.
final class RemoteConfig {
  const RemoteConfig({
    this.version = 0,
    this.homeRows,
    this.featureFlags = const <String, bool>{},
    this.announcements = const <RemoteAnnouncement>[],
    this.danmakuSources = const <Map<String, String>>[],
    this.openlistPresets = const <Map<String, String>>[],
    this.signature = '',
  });

  final int version;

  /// Ordered row ids for the home page. `null` means "client keeps its built-in
  /// order"; an explicit list reorders/removes rows by id. Unknown ids ignored.
  final List<String>? homeRows;

  final Map<String, bool> featureFlags;
  final List<RemoteAnnouncement> announcements;
  final List<Map<String, String>> danmakuSources;
  final List<Map<String, String>> openlistPresets;

  /// HMAC-SHA256 over the canonical (key-sorted) JSON body without this field.
  final String signature;

  bool get isEmpty => version <= 0 && homeRows == null && featureFlags.isEmpty && announcements.isEmpty;

  bool feature(String key, {bool fallback = false}) => featureFlags[key] ?? fallback;

  /// Parse a signed server payload. Returns null when the shape is invalid or
  /// the signature does not match [key] — a tampered/legacy payload is never
  /// applied. [key] mirrors the server's CONFIG_SIGNING_KEY/ADMIN_TOKEN.
  ///
  /// Verification is done over the *raw* body (keys sorted, `signature`
  /// excluded) so it matches the server's `canonicalConfig` byte-for-byte,
  /// independent of how this model normalizes fields.
  static RemoteConfig? parse(Object? decoded, {required String key}) {
    if (decoded is! Map) return null;
    final version = (decoded['version'] as num?)?.toInt() ?? 0;
    if (version < 0) return null;

    final signature = '${decoded['signature'] ?? ''}';
    // When a signing key is configured, a payload MUST carry a valid signature.
    // Accepting an unsigned payload here would let a tamperer simply strip the
    // `signature` field to bypass verification entirely.
    if (key.isNotEmpty && (signature.isEmpty || !verifySignature(decoded, key: key))) return null;

    List<String>? rows;
    final rawRows = decoded['homeRows'];
    if (rawRows is List) rows = [for (final r in rawRows) '$r'];

    final flags = <String, bool>{};
    final rawFlags = decoded['featureFlags'];
    if (rawFlags is Map) {
      rawFlags.forEach((k, v) {
        if (v is bool) flags['$k'] = v;
      });
    }

    final announcements = <RemoteAnnouncement>[];
    final rawAnn = decoded['announcements'];
    if (rawAnn is List) {
      for (final a in rawAnn) {
        if (a is Map) {
          final text = '${a['text'] ?? ''}';
          if (text.trim().isEmpty) continue;
          announcements.add(RemoteAnnouncement(
            id: '${a['id'] ?? ''}',
            text: text,
            url: '${a['url'] ?? ''}',
          ));
        }
      }
    }

    return RemoteConfig(
      version: version,
      homeRows: rows,
      featureFlags: flags,
      announcements: announcements,
      danmakuSources: _stringMapList(decoded['danmakuSources']),
      openlistPresets: _stringMapList(decoded['openlistPresets']),
      signature: signature,
    );
  }

  static List<Map<String, String>> _stringMapList(Object? raw) {
    final out = <Map<String, String>>[];
    if (raw is! List) return out;
    for (final e in raw) {
      if (e is! Map) continue;
      out.add({for (final k in e.keys) '$k': '${e[k]}'});
    }
    return out;
  }

  /// Recursively sort object keys — identical to the server's canonical form.
  static Object? _sorted(Object? v) {
    if (v is List) return [for (final e in v) _sorted(e)];
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: _sorted(v[k])};
    }
    return v;
  }

  /// Verify the `signature` field against the canonical body. Exposed so the
  /// same payload verification can be reused by other services (sync, later).
  static bool verifySignature(Map decoded, {required String key}) {
    final body = <String, Object?>{};
    decoded.forEach((k, v) {
      if ('$k' != 'signature') body['$k'] = v;
    });
    final canonical = jsonEncode(_sorted(body));
    final digest = Hmac(sha256, utf8.encode(key)).convert(utf8.encode(canonical)).toString();
    return digest == '${decoded['signature'] ?? ''}';
  }
}

final class RemoteAnnouncement {
  const RemoteAnnouncement({required this.id, required this.text, required this.url});

  final String id;
  final String text;
  final String url;

  Map<String, Object?> toJson() => {'id': id, 'text': text, 'url': url};
}
