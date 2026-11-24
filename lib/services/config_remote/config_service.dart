import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/host.dart';
import '../../core/storage/local_store.dart';
import 'remote_config.dart';

/// Fetches, verifies and caches the signed hot-reload config.
///
/// Graceful degradation is a hard requirement: with no distribution service,
/// or on any network/parse/signature failure, [config] stays null and the app
/// keeps its built-in behaviour. Config loads are best-effort and never throw
/// to callers.
final class ConfigService {
  ConfigService({
    http.Client? client,
    required LocalStore store,
    required String baseUrl,
    required String channel,
    required String signingKey,
    String? platform,
    Duration ttl = const Duration(minutes: 30),
  })  : _client = client ?? http.Client(),
        _store = store,
        _baseUrl = baseUrl,
        _channel = channel,
        _signingKey = signingKey,
        _platform = platform ?? _detectPlatform(),
        _ttl = ttl;

  final http.Client _client;
  final LocalStore _store;
  final String _baseUrl;
  final String _channel;
  final String _signingKey;
  final String _platform;
  final Duration _ttl;

  static const _cacheKey = 'aushd.remote_config.json';
  static const _fetchedAtKey = 'aushd.remote_config.fetched_at';

  static String _detectPlatform() => Host.isWindows ? 'windows' : Host.isAndroid ? 'androidtv' : 'linux';

  RemoteConfig? _memory;
  RemoteConfig? get config => _memory;

  bool get available => _baseUrl.isNotEmpty;

  _CacheMeta _meta = const _CacheMeta(version: 0, fetchedAt: 0);
  int get appliedVersion => _memory?.version ?? _meta.version;

  /// Load the last verified config from disk. Safe to call at startup.
  Future<RemoteConfig?> loadCached() async {
    final raw = await _store.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return _memory;
    try {
      final decoded = jsonDecode(raw);
      final cfg = RemoteConfig.parse(decoded, key: _signingKey);
      if (cfg != null) _memory = cfg;
    } catch (e) {
      debugPrint('[config] cached parse failed: $e');
    }
    final at = int.tryParse(await _store.getString(_fetchedAtKey) ?? '') ?? 0;
    _meta = _CacheMeta(version: _memory?.version ?? 0, fetchedAt: at);
    return _memory;
  }

  /// Fetch only when due (TTL elapsed) or [force] is set. Always best-effort:
  /// failures leave the previously cached config in place.
  Future<RemoteConfig?> refresh({bool force = false}) async {
    if (_baseUrl.isEmpty) return _memory;
    if (!force && !_due) return _memory;

    final base = Uri.parse(_baseUrl);
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    final url = base.replace(path: '$prefix/api/config').replace(queryParameters: {
      'platform': _platform,
      'channel': _channel,
      'tag': '$appliedVersion',
    });

    try {
      final res = await _client.get(url, headers: {'accept': 'application/json'}).timeout(const Duration(seconds: 15));
      if (res.statusCode == 204 || res.statusCode == 404) {
        await _touch();
        return _memory;
      }
      if (res.statusCode != 200) {
        debugPrint('[config] server answered ${res.statusCode}');
        return _memory;
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final cfg = RemoteConfig.parse(decoded, key: _signingKey);
      if (cfg == null) {
        debugPrint('[config] rejected unsigned/invalid config');
        return _memory;
      }
      if (cfg.version < appliedVersion) return _memory;
      _memory = cfg;
      await _store.setString(_cacheKey, jsonEncode(decoded));
      await _touch(version: cfg.version);
      return cfg;
    } catch (e) {
      debugPrint('[config] refresh failed: $e');
      return _memory;
    }
  }

  bool get _due => DateTime.now().millisecondsSinceEpoch - _meta.fetchedAt >= _ttl.inMilliseconds;

  Future<void> _touch({int? version}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _meta = _CacheMeta(version: version ?? _meta.version, fetchedAt: now);
    await _store.setString(_fetchedAtKey, '$now');
  }

  /// Reorder/filter home row ids according to the remote config.
  ///
  /// - null/empty config → identity
  /// - rows whose id is in [known] keep their remote order; ids not listed in
  ///   the config are appended in their original order so a partial remote
  ///   list never hides entire zones by accident.
  List<T> applyRowOrder<T>(List<T> rows, String Function(T) idOf) {
    final remote = _memory?.homeRows;
    if (remote == null || remote.isEmpty) return rows;
    final byId = <String, T>{};
    // Keep first occurrence when ids duplicate locally.
    for (final row in rows) {
      byId.putIfAbsent(idOf(row), () => row);
    }
    final out = <T>[];
    final used = <String>{};
    for (final id in remote) {
      final row = byId[id];
      if (row != null && used.add(id)) out.add(row);
    }
    for (final row in rows) {
      final id = idOf(row);
      if (!used.contains(id)) out.add(row);
    }
    return out;
  }
}

final class _CacheMeta {
  const _CacheMeta({required this.version, required this.fetchedAt});
  final int version;
  final int fetchedAt;
}
