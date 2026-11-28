import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/blob_store.dart';

/// One locally cached scraper decision. [data] is null for a cached miss.
final class ScraperCacheEntry {
  const ScraperCacheEntry({required this.time, required this.data, required this.hit});

  final DateTime time;
  final Map<String, dynamic>? data;
  final bool hit;
}

/// Local-only cache of smart-scraper results.
///
/// Keys are intentionally independent of the upstream item id (a re-import or
/// a different server changes that). Nothing here is ever written back to the
/// user's media library.
final class ScraperCache {
  ScraperCache._() {
    ready = _load();
  }

  static final instance = ScraperCache._();

  late final Future<void> ready;
  final _entries = <String, ScraperCacheEntry>{};
  Timer? _saveTimer;

  static const _ttl = Duration(days: 30);
  static const _missingTtl = Duration(days: 2);
  static const _name = 'scraper_cache.json';

  ScraperCacheEntry? lookup(String key) {
    final e = _entries[key];
    if (e == null) return null;
    return DateTime.now().difference(e.time) < (e.hit ? ttl : missingTtl) ? e : null;
  }

  Duration get ttl => _ttl;
  Duration get missingTtl => _missingTtl;

  /// Stores a hit or a miss. Misses are remembered briefly so the same broken
  /// filename is not re-queried on every scroll.
  void store(String key, Map<String, dynamic>? data) {
    _entries[key] = ScraperCacheEntry(time: DateTime.now(), data: data, hit: data != null);
    _scheduleSave();
  }

  Future<void> clear() async {
    await ready;
    _entries.clear();
    _saveTimer?.cancel();
    try {
      await deleteBlob(_name);
    } catch (_) {}
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_save());
    });
  }

  Future<void> _load() async {
    try {
      final text = await readBlob(_name);
      if (text == null) return;
      final raw = await compute(_decode, text);
      raw.forEach((k, v) {
        if (v is! Map) return;
        final t = v['t'];
        if (t is! int) return;
        _entries[k] = ScraperCacheEntry(
          time: DateTime.fromMillisecondsSinceEpoch(t),
          data: (v['d'] as Map?)?.cast<String, dynamic>(),
          hit: v['h'] == true,
        );
      });
    } catch (e) {
      debugPrint('[scraper] cache load failed: $e');
    }
  }

  static Map<String, dynamic> _decode(String text) => jsonDecode(text) as Map<String, dynamic>;

  Future<void> _save() async {
    final now = DateTime.now();
    _entries.removeWhere((_, e) => now.difference(e.time) > (e.hit ? _ttl : _missingTtl));
    try {
      final doc = {
        for (final e in _entries.entries)
          e.key: {'t': e.value.time.millisecondsSinceEpoch, 'd': e.value.data, 'h': e.value.hit},
      };
      await writeBlob(_name, await compute(jsonEncode, doc));
    } catch (e) {
      debugPrint('[scraper] cache save failed: $e');
    }
  }
}

/// Build a stable cache key. Prefers explicit provider ids, then normalized
/// title+year, then a hash of the source path as a last resort.
String scraperCacheKey({
  String? tmdbId,
  String? imdbId,
  required String name,
  int? year,
  String? path,
}) {
  final buffer = StringBuffer();
  if (tmdbId != null && tmdbId.isNotEmpty) {
    buffer.write('tmdb:$tmdbId');
  } else if (imdbId != null && imdbId.isNotEmpty) {
    buffer.write('imdb:$imdbId');
  } else {
    final normalized = normalizeForMatch(name);
    if (normalized.isEmpty) {
      // A path hash is stable across re-imports as long as the file location
      // does not move. Never uses the upstream item id.
      buffer.write('path:${_hash(path ?? name)}');
    } else {
      buffer.write('name:$normalized');
      if (year != null) buffer.write(':$year');
    }
  }
  return buffer.toString();
}

String normalizeForMatch(String s) {
  var t = s.toLowerCase();
  t = t.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _hash(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toUnsigned(64).toRadixString(16);
}
