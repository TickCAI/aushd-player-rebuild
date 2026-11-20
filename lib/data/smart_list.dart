import 'dart:math' as math;

import '../core/emby/models/emby_item.dart';
import 'catalog_api.dart';
import 'taste_profile.dart';

/// Where a smart list gets its candidates.
enum SmartKind { emby, nextUp, seerr, hybrid, local }

/// A declarative shelf definition. Deliberately free of Flutter and I/O so the
/// scoring / filtering / hiding rules can be unit-tested on the VM.
final class SmartSpec {
  const SmartSpec({
    required this.id,
    required this.kind,
    this.types,
    this.sortBy = 'SortName',
    this.descending = false,
    this.filters,
    this.minRating,
    this.maxRating,
    this.maxYear,
    this.genres,
    this.years,
    this.windowDays,
    this.windowField = 'DateCreated',
    this.minItems = 4,
    this.limit = 24,
    this.score = false,
    this.requiresSeerr = false,
  });

  final String id;
  final SmartKind kind;
  final List<String>? types;
  final String sortBy;
  final bool descending;
  final String? filters;
  final double? minRating;
  final double? maxRating;
  final int? maxYear;
  final List<String>? genres;
  final List<int>? years;
  final int? windowDays;
  final String windowField;
  final int minItems;
  final int limit;
  final bool score;
  final bool requiresSeerr;

  /// A shelf is dropped entirely (not shown as "empty") below this count.
  bool hides(List<Object> items) => items.length < minItems;

  static const thisWeek = SmartSpec(
    id: 'this-week',
    kind: SmartKind.emby,
    types: ['Episode', 'Series'],
    sortBy: 'DateCreated',
    descending: true,
    windowDays: 7,
    minItems: 4,
    limit: 24,
  );

  static const classics = SmartSpec(
    id: 'classics',
    kind: SmartKind.emby,
    types: ['Movie', 'Series'],
    minRating: 8,
    maxYear: 2015,
    filters: 'IsUnplayed',
    sortBy: 'CommunityRating',
    descending: true,
    score: true,
    minItems: 6,
    limit: 24,
  );

  static const fresh = SmartSpec(
    id: 'fresh',
    kind: SmartKind.emby,
    types: ['Movie', 'Series'],
    sortBy: 'PremiereDate',
    descending: true,
    windowDays: 90,
    windowField: 'PremiereDate',
    minItems: 4,
    limit: 24,
  );

  static const gems = SmartSpec(
    id: 'gems',
    kind: SmartKind.emby,
    types: ['Movie', 'Series'],
    minRating: 6.5,
    maxRating: 7.8,
    filters: 'IsUnplayed',
    sortBy: 'CommunityRating',
    descending: true,
    score: true,
    minItems: 6,
    limit: 24,
  );

  static const oneEp = SmartSpec(
    id: 'one-ep',
    kind: SmartKind.nextUp,
    minItems: 4,
    limit: 24,
  );

  static const picks = SmartSpec(
    id: 'picks',
    kind: SmartKind.emby,
    types: ['Movie', 'Series'],
    filters: 'IsUnplayed',
    minRating: 7,
    sortBy: 'CommunityRating',
    descending: true,
    score: true,
    minItems: 6,
    limit: 24,
  );

  /// Defined for the "more" filter page; the home page keeps its richer
  /// profile-backed My-list row instead of this coarse query.
  static const myList = SmartSpec(id: 'my-list', kind: SmartKind.local, minItems: 1, limit: 60);

  /// The seven shelves that can back a home row (Seerr trending is handled by
  /// the existing Seerr row, kept as-is).
  static const home = <SmartSpec>[thisWeek, classics, fresh, gems, oneEp, picks];

  static SmartSpec? byId(String id) {
    for (final s in home) {
      if (s.id == id) return s;
    }
    return id == myList.id ? myList : null;
  }
}

/// CommunityRating / 10, clamped. Missing rating is neutral, not a penalty
/// larger than a low score.
double normRating(double? rating) {
  if (rating == null) return 0;
  return (rating / 10).clamp(0.0, 1.0);
}

/// FNV-1a folded into [0,1): deterministic per id so a shelf's order does not
/// reshuffle on every refresh.
double stableJitter(String id) {
  var h = 0x811c9dc5;
  for (final c in id.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return (h % 10000) / 10000;
}

/// Newer is better, 3-year half-life, based on the best available date.
double freshness(EmbyItem item, {DateTime? now}) {
  final date = item.premiereDate ??
      item.dateCreated ??
      (item.productionYear == null ? null : DateTime.utc(item.productionYear!, 1, 1));
  if (date == null) return 0.3;
  final days = (now ?? DateTime.now()).difference(date).inDays;
  if (days <= 0) return 1;
  return math.pow(0.5, days / (365.25 * 3)).toDouble();
}

/// Fraction of the taste dimensions (genre / actor / director) an item hits.
double tasteMatch(EmbyItem item, TasteProfile taste) {
  var hits = 0;
  var total = 0;
  final genres = {for (final g in taste.genres) g.genre.toLowerCase()};
  if (genres.isNotEmpty) {
    total++;
    if (item.genres.any((g) => genres.contains(g.toLowerCase()))) hits++;
  }
  final actors = {for (final f in taste.actors) f.person.id};
  if (actors.isNotEmpty) {
    total++;
    if (item.people.any((p) => p.type == 'Actor' && actors.contains(p.id))) hits++;
  }
  final directors = {for (final f in taste.directors) f.person.id};
  if (directors.isNotEmpty) {
    total++;
    if (item.people.any((p) => p.type == 'Director' && directors.contains(p.id))) hits++;
  }
  return total == 0 ? 0 : hits / total;
}

/// 0.45 rating + 0.30 taste + 0.15 freshness + 0.10 stable jitter.
double itemScore(EmbyItem item, TasteProfile taste, {DateTime? now}) =>
    0.45 * normRating(item.communityRating) +
    0.30 * tasteMatch(item, taste) +
    0.15 * freshness(item, now: now) +
    0.10 * stableJitter(item.id);

List<EmbyItem> scoreSort(Iterable<EmbyItem> items, TasteProfile taste, {DateTime? now}) {
  final scored = [for (final i in items) (item: i, score: itemScore(i, taste, now: now))];
  scored.sort((a, b) {
    final c = b.score.compareTo(a.score);
    return c != 0 ? c : a.item.id.compareTo(b.item.id);
  });
  return [for (final e in scored) e.item];
}

/// Keep the first occurrence of each id — a series and a duplicate episode must
/// not occupy two slots on one shelf.
List<EmbyItem> dedupeById(Iterable<EmbyItem> items) {
  final seen = <String>{};
  return [for (final i in items) if (seen.add(i.id)) i];
}

bool _inWindow(EmbyItem item, SmartSpec spec, DateTime now) {
  if (spec.windowDays == null) return true;
  final date = spec.windowField == 'PremiereDate' ? item.premiereDate : item.dateCreated;
  if (date == null) return false;
  final days = now.difference(date).inDays;
  return days >= 0 && days <= spec.windowDays!;
}

/// Server-side query params cover most rules; this is the local safety net for
/// the ones Emby cannot express (upper rating bound, year ceiling, time window).
bool matchesLocal(EmbyItem item, SmartSpec spec, {DateTime? now}) {
  if (!_inWindow(item, spec, now ?? DateTime.now())) return false;
  if (spec.maxRating != null && (item.communityRating ?? 0) > spec.maxRating!) return false;
  if (spec.maxYear != null && (item.productionYear ?? 9999) > spec.maxYear!) return false;
  if (spec.filters?.contains('IsUnplayed') == true && item.isPlayed) return false;
  return true;
}

/// Turns a declarative spec into a shelf of library items. Pure enough to be
/// driven in tests with a stub catalog; no Flutter, no I/O beyond CatalogApi.
final class SmartListResolver {
  SmartListResolver(this._catalog, this._taste);

  final CatalogApi _catalog;
  final TasteProfile _taste;

  /// In-memory TTL cache (§5.3). Keyed by spec id + taste genres so a rebuild
  /// after a settings change does not re-hit the server within the window.
  static final Map<String, ({List<EmbyItem> items, DateTime at})> _cache = {};
  static const _ttl = Duration(minutes: 30);

  /// Drop cached shelves when the library changes.
  static void invalidate() => _cache.clear();

  Future<List<EmbyItem>> resolve(SmartSpec spec, {DateTime? now, List<String>? tasteGenres}) async {
    final at = now ?? DateTime.now();
    final key = '${spec.id}|${(tasteGenres ?? _taste.genres.take(3).map((g) => g.genre).toList()).join(',')}';
    final hit = _cache[key];
    if (hit != null && at.difference(hit.at) < _ttl) return hit.items;

    final List<EmbyItem> result;
    switch (spec.kind) {
      case SmartKind.local:
      case SmartKind.seerr:
      case SmartKind.hybrid:
        result = const <EmbyItem>[];

      case SmartKind.nextUp:
        final up = await _catalog.nextUp(limit: spec.limit);
        final seen = <String>{};
        result = [for (final i in up) if (i.seriesId != null && seen.add(i.seriesId!)) i].take(spec.limit).toList();

      case SmartKind.emby:
        final genres = tasteGenres ?? _taste.genres.take(3).map((g) => g.genre).toList();
        final page = await _catalog.query(
          types: spec.types,
          sortBy: spec.sortBy,
          descending: spec.descending,
          filters: spec.filters,
          minCommunityRating: spec.minRating,
          genres: spec.id == picks.id && genres.isNotEmpty ? genres : null,
          years: spec.years,
          // Scored shelves need People for the actor/director half of tasteMatch.
          fields: spec.score ? '${CatalogApi.cardFields},People' : CatalogApi.cardFields,
          limit: spec.limit,
        );
        var items = [for (final i in page.items) if (matchesLocal(i, spec, now: at)) i];
        if (spec.score) items = scoreSort(items, _taste, now: at);
        result = dedupeById(items).take(spec.limit).toList();
    }
    // Below minItems the whole shelf is suppressed (§3.2) — an almost-empty
    // row reads as broken, so return nothing rather than a "no content" stub.
    final shelf = spec.hides(result) ? const <EmbyItem>[] : result;
    _cache[key] = (items: shelf, at: at);
    return shelf;
  }
}
