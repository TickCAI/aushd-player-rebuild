import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/storage/local_store.dart';
import 'danmaku.dart';

/// Identity of the media currently playing, used to look up its danmaku.
final class DanmakuMedia {
  const DanmakuMedia({this.tmdbId, this.doubanId, this.title, this.season, this.episode});

  final int? tmdbId;
  final String? doubanId;
  final String? title;
  final int? season;
  final int? episode;

  /// A stable cache key across providers for the same episode.
  String get key => [
        tmdbId ?? '-',
        doubanId ?? '-',
        title ?? '-',
        season ?? '-',
        episode ?? '-',
      ].join(':');
}

/// A danmaku data source. Implementations map a [DanmakuMedia] to a list of
/// [Danmaku]. Providers are pure lookups: they never touch the player.
abstract interface class DanmakuProvider {
  /// Stable id, used in settings and to persist the user's choice.
  String get id;

  /// Human-readable name shown in the danmaku-source picker.
  String get displayName;

  /// Whether this provider can serve [media] at all (e.g. needs a tmdb id).
  bool supports(DanmakuMedia media);

  /// Fetch danmaku for [media]. Must not throw for "no results" — return an
  /// empty list instead; genuine failures may throw and are caught upstream.
  Future<List<Danmaku>> fetch(DanmakuMedia media);
}

/// A provider backed by an HTTP template, so new sources ship via the signed
/// config (阶段1) without a Dart change.
///
/// [urlTemplate] placeholders: `{tmdb}` `{douban}` `{title}` `{season}`
/// `{episode}`. The response is auto-detected (Bilibili XML or JSON).
final class TemplateDanmakuProvider implements DanmakuProvider {
  TemplateDanmakuProvider({
    required this.id,
    required this.displayName,
    required this.urlTemplate,
    this.requiresTmdb = true,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  final String id;
  @override
  final String displayName;
  final String urlTemplate;
  final bool requiresTmdb;
  final http.Client _client;

  @override
  bool supports(DanmakuMedia media) =>
      !requiresTmdb || media.tmdbId != null || (media.doubanId?.isNotEmpty ?? false);

  String _fill(DanmakuMedia media) => urlTemplate
      .replaceAll('{tmdb}', '${media.tmdbId ?? ''}')
      .replaceAll('{douban}', media.doubanId ?? '')
      .replaceAll('{title}', Uri.encodeComponent(media.title ?? ''))
      .replaceAll('{season}', '${media.season ?? ''}')
      .replaceAll('{episode}', '${media.episode ?? ''}');

  @override
  Future<List<Danmaku>> fetch(DanmakuMedia media) async {
    final url = _fill(media);
    if (!url.startsWith('http')) return const [];
    final res = await _client
        .get(Uri.parse(url), headers: {'accept': 'application/json, text/xml'})
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    return DanmakuCodec.parseAuto(utf8.decode(res.bodyBytes));
  }
}

/// Registry + cache. Owns the enabled flag, the chosen provider and a short
/// in-memory cache so toggling danmaku off/on does not re-hit the network.
///
/// Providers are supplied by the signed config (阶段1 `danmakuSources`); with
/// none configured the service is inert and danmaku stays silently off.
final class DanmakuService extends ChangeNotifier {
  DanmakuService({List<DanmakuProvider>? providers, LocalStore? store})
      : _configProviders = [if (providers != null) ...providers],
        _store = store {
    _rebuild();
  }

  static const _prefsKey = 'aushd.danmaku.v1';

  /// Sources from the signed remote config (阶段1). Replaced on config refresh.
  final List<DanmakuProvider> _configProviders;

  /// Sources the user added themselves in Settings. Persisted locally so
  /// danmaku works even when no remote config / signing key is configured.
  final List<Map<String, String>> _userSources = [];

  /// Effective provider list = config + user sources.
  final List<DanmakuProvider> _providers = [];
  final LocalStore? _store;
  final Map<String, List<Danmaku>> _cache = {};
  static const _cacheLimit = 40;

  bool _enabled = false;
  String _providerId = '';

  bool get enabled => _enabled && _provider != null;
  bool get hasProviders => _providers.isNotEmpty;
  String get providerId => _provider?.id ?? '';
  List<DanmakuProvider> get providers => List.unmodifiable(_providers);

  DanmakuProvider? get _provider {
    if (_providers.isEmpty) return null;
    for (final p in _providers) {
      if (p.id == _providerId) return p;
    }
    return _providers.first;
  }

  /// Restore the persisted choice. Safe to call before the config sources
  /// arrive; the enabled flag simply stays inert until a provider exists.
  Future<void> restorePrefs() async {
    final raw = await _store?.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final j = jsonDecode(raw) as Map;
      _enabled = j['enabled'] == true;
      _providerId = '${j['provider'] ?? ''}';
      final sources = j['sources'];
      if (sources is List) {
        _userSources
          ..clear()
          ..addAll(sources.whereType<Map>().map((m) => {
                'id': '${m['id'] ?? ''}',
                'name': '${m['name'] ?? ''}',
                'url': '${m['url'] ?? ''}',
                'requiresTmdb': '${m['requiresTmdb'] ?? 'true'}',
              }));
        _rebuild();
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    final store = _store;
    if (store == null) return;
    await store.setString(_prefsKey, jsonEncode({
      'enabled': _enabled,
      'provider': _providerId,
      'sources': _userSources,
    }));
  }

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    unawaited(_persist());
    notifyListeners();
  }

  void setProvider(String id) {
    if (_providerId == id) return;
    _providerId = id;
    _cache.clear();
    unawaited(_persist());
    notifyListeners();
  }

  /// Replace the config-provided sources (from signed config). User sources
  /// are preserved. Each entry is `{id, name, url, requiresTmdb?}`.
  void applyConfigSources(List<Map<String, String>> sources, {http.Client? client}) {
    final built = <DanmakuProvider>[];
    for (final s in sources) {
      final id = s['id']?.trim();
      final url = s['url']?.trim();
      if (id == null || id.isEmpty || url == null || url.isEmpty) continue;
      built.add(TemplateDanmakuProvider(
        id: id,
        displayName: s['name']?.trim() ?? id,
        urlTemplate: url,
        requiresTmdb: s['requiresTmdb'] != 'false',
        client: client,
      ));
    }
    _configProviders
      ..clear()
      ..addAll(built);
    _rebuild();
  }

  /// Rebuild the effective provider list from config + user sources.
  void _rebuild() {
    final built = <DanmakuProvider>[..._configProviders];
    for (final s in _userSources) {
      final id = s['id']?.trim();
      final url = s['url']?.trim();
      if (id == null || id.isEmpty || url == null || url.isEmpty) continue;
      built.add(TemplateDanmakuProvider(
        id: id,
        displayName: (s['name']?.trim()?.isNotEmpty ?? false) ? s['name']!.trim() : id,
        urlTemplate: url,
        requiresTmdb: s['requiresTmdb'] != 'false',
      ));
    }
    _providers
      ..clear()
      ..addAll(built);
    _cache.clear();
    if (_providers.isNotEmpty && _providers.every((p) => p.id != _providerId)) {
      _providerId = _providers.first.id;
    }
    if (_providers.isEmpty) _enabled = false;
    notifyListeners();
  }

  /// Add a user-defined source. [name] is the display label, [url] a template
  /// supporting {tmdb}/{douban}/{title}/{season}/{episode}. Returns its id.
  String addUserSource({required String name, required String url, bool requiresTmdb = true}) {
    final id = 'user-${DateTime.now().microsecondsSinceEpoch}';
    _userSources.add({
      'id': id,
      'name': name.trim(),
      'url': url.trim(),
      'requiresTmdb': requiresTmdb.toString(),
    });
    _providerId = id;
    _enabled = true;
    unawaited(_persist());
    _rebuild();
    return id;
  }

  void removeUserSource(String id) {
    if (!_userSources.any((s) => s['id'] == id)) return;
    _userSources.removeWhere((s) => s['id'] == id);
    if (_providerId == id) _providerId = '';
    unawaited(_persist());
    _rebuild();
  }

  bool isUserSource(String id) => _userSources.any((s) => s['id'] == id);

  /// Danmaku for [media], using the cache when warm. Returns empty when
  /// disabled, unsupported, or on any failure — danmaku is always optional.
  Future<List<Danmaku>> load(DanmakuMedia media) async {
    if (!enabled) return const [];
    final provider = _provider;
    if (provider == null || !provider.supports(media)) return const [];
    final cacheKey = '${provider.id}|${media.key}';
    final hit = _cache[cacheKey];
    if (hit != null) return hit;
    try {
      final items = await provider.fetch(media);
      if (_cache.length >= _cacheLimit) _cache.clear();
      _cache[cacheKey] = items;
      return items;
    } catch (e) {
      debugPrint('[danmaku] ${provider.id} fetch failed: $e');
      return const [];
    }
  }
}
