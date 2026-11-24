import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aushd_player/core/storage/local_store.dart';
import 'package:aushd_player/services/config_remote/config_service.dart';
import 'package:aushd_player/services/config_remote/remote_config.dart';

void main() {
  const key = 'test-signing-key';

  Map<String, Object?> signedBody(Map<String, Object?> body) {
    final payload = Map<String, Object?>.from(body);
    Object sort(Object? v) {
      if (v is List) return [for (final e in v) sort(e)];
      if (v is Map) {
        final keys = v.keys.map((k) => '$k').toList()..sort();
        return {for (final k in keys) k: sort(v[k])};
      }
      return v;
    }

    final canonical = jsonEncode(sort(payload));
    payload['signature'] = Hmac(sha256, utf8.encode(key)).convert(utf8.encode(canonical)).toString();
    return payload;
  }

  group('RemoteConfig.parse', () {
    test('accepts a correctly signed payload', () {
      final body = signedBody({
        'version': 3,
        'homeRows': ['continueWatching', 'trending'],
        'featureFlags': {'danmaku': true, 'openlist': false},
        'announcements': [
          {'id': 'a1', 'text': 'Hello', 'url': ''},
        ],
        'danmakuSources': [],
        'openlistPresets': [],
      });
      final cfg = RemoteConfig.parse(body, key: key);
      expect(cfg, isNotNull);
      expect(cfg!.version, 3);
      expect(cfg.homeRows, ['continueWatching', 'trending']);
      expect(cfg.feature('danmaku'), true);
      expect(cfg.feature('openlist'), false);
      expect(cfg.feature('missing', fallback: true), true);
      expect(cfg.announcements.length, 1);
    });

    test('rejects a tampered signature', () {
      final body = signedBody({'version': 3, 'homeRows': ['trending']});
      body['version'] = 99; // tamper after signing
      expect(RemoteConfig.parse(body, key: key), isNull);
    });

    test('rejects a payload signed with the wrong key', () {
      final body = signedBody({'version': 1});
      expect(RemoteConfig.parse(body, key: 'wrong-key'), isNull);
    });

    test('allows unsigned payload when key is empty (dev mode)', () {
      final cfg = RemoteConfig.parse({'version': 2, 'featureFlags': {'x': true}}, key: '');
      expect(cfg, isNotNull);
      expect(cfg!.version, 2);
    });

    test('rejects negative version', () {
      expect(RemoteConfig.parse(signedBody({'version': -1}), key: key), isNull);
    });
  });

  group('ConfigService.applyRowOrder', () {
    Future<ConfigService> makeService({Map<String, Object?>? signed}) async {
      final store = _MemoryStore();
      if (signed != null) {
        await store.setString('aushd.remote_config.json', jsonEncode(signed));
      }
      final svc = ConfigService(
        store: store,
        baseUrl: '',
        channel: 'stable',
        signingKey: key,
        platform: 'windows',
      );
      await svc.loadCached();
      return svc;
    }

    test('no config keeps original order', () async {
      final svc = await makeService();
      expect(svc.applyRowOrder(['a', 'b', 'c'], (s) => s), ['a', 'b', 'c']);
    });

    test('reorders known ids first, appends the rest', () async {
      final svc = await makeService(signed: signedBody({'version': 1, 'homeRows': ['c', 'a']}));
      expect(svc.applyRowOrder(['a', 'b', 'c'], (s) => s), ['c', 'a', 'b']);
    });

    test('unknown remote ids are ignored', () async {
      final svc = await makeService(signed: signedBody({'version': 1, 'homeRows': ['z', 'b']}));
      expect(svc.applyRowOrder(['a', 'b', 'c'], (s) => s), ['b', 'a', 'c']);
    });

    test('tampered cached config is not applied', () async {
      final store = _MemoryStore();
      final body = signedBody({'version': 1, 'homeRows': ['c']});
      body['version'] = 9;
      await store.setString('aushd.remote_config.json', jsonEncode(body));
      final svc = ConfigService(store: store, baseUrl: '', channel: 'stable', signingKey: key, platform: 'windows');
      await svc.loadCached();
      expect(svc.config, isNull);
      expect(svc.applyRowOrder(['a', 'b', 'c'], (s) => s), ['a', 'b', 'c']);
    });
  });
}

class _MemoryStore implements LocalStore {
  final Map<String, String> _data = {};

  @override
  Future<void> init() async {}

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> setString(String key, String value) async => _data[key] = value;

  @override
  Future<void> remove(String key) async => _data.remove(key);
}
