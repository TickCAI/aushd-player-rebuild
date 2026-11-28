/// Visibility-driven smart scraper.
///
/// Fills missing artwork/text for library items the upstream media server never
/// scraped (mounted network drives, freshly imported libraries). Everything it
/// produces lives in a LOCAL cache and is applied as a render-time overlay via
/// EmbyItem.copyWith — nothing is ever written back to the user's media server.
///
/// Design rules (agreed with the user):
///  * zero write-back to the upstream library;
///  * a missing poster stays missing rather than showing a WRONG poster;
///  * cache keys never use the upstream item.id (re-imports change it);
///  * results are clearable in one step.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/emby/models/emby_item.dart';
import '../tmdb_api.dart';
import 'filename_guess.dart';
import 'match_score.dart';
import 'scraper_cache.dart';

/// Applies a locally scraped decision to an item, in memory only.
final class ScrapeResult {
  const ScrapeResult({
    required this.item,
    required this.applied,
    required this.verdict,
    this.reason = '',
  });

  /// The (possibly updated) item. Equal to the input when nothing was applied.
  final EmbyItem item;
  final bool applied;
  final String verdict;
  final String reason;
}

/// Tiny concurrency limiter so a burst of rows cannot hammer TMDB.
final class _Gate {
  _Gate(this._max);
  final int _max;
  int _active = 0;
  final List<Completer<void>> _waiting = [];

  Future<void> acquire() async {
    if (_active < _max) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      final c = _waiting.removeAt(0);
      if (!c.isCompleted) c.complete();
      // Ownership transfers to the waiter; _active is unchanged.
    } else if (_active > 0) {
      _active--;
    }
  }
}

/// Scrapes missing metadata from filenames using TMDB search, with a strict
/// confidence gate. Safe to call from a scroll callback: work is deduplicated
/// and concurrency-limited, and cache hits cost no network at all.
final class SmartScraper extends ChangeNotifier {
  SmartScraper({this.tmdb, this.language = 'zh-CN'}) : _gate = _Gate(3) {
    unawaited(ScraperCache.instance.ready);
  }

  final TmdbApi? tmdb;
  final String language;
  final _Gate _gate;
  final Map<String, Future<ScrapeResult>> _inFlight = {};

  int _applied = 0;
  int _attempted = 0;

  /// Completes when the local cache has finished loading from disk.
  Future<void> get ready => ScraperCache.instance.ready;

  /// True when a TMDB key is configured. When false every scrape is a no-op.
  bool get available => tmdb != null;

  int get appliedCount => _applied;
  int get attemptedCount => _attempted;

  static const _maxCandidates = 5;

  /// Returns a (possibly updated) copy of [item]. Never returns a different
  /// identity than the input when the decision is not confident enough to
  /// apply — callers can always keep rendering the original.
  Future<ScrapeResult> scrape(EmbyItem item) async {
    if (tmdb == null) return ScrapeResult(item: item, applied: false, verdict: 'skip', reason: 'no-tmdb-key');
    if (item.tmdbId != null) {
      return ScrapeResult(item: item, applied: false, verdict: 'skip', reason: 'has-provider-id');
    }
    // Only movie / series / episode rows benefit from a filename guess.
    if (!item.isMovie && !item.isSeries && item.type != 'Episode') {
      return ScrapeResult(item: item, applied: false, verdict: 'skip', reason: 'type');
    }

    final filePath = _sourcePath(item);
    final guess = filePath == null ? null : const FilenameGuesser().guess(_basename(filePath));
    if (guess == null && (item.name.trim().isEmpty)) {
      return ScrapeResult(item: item, applied: false, verdict: 'skip', reason: 'no-query');
    }

    final queryTitle = (guess?.title.isNotEmpty ?? false) ? guess!.title : item.name.trim();
    final queryYear = guess?.year ?? item.productionYear;
    final queryIsTv = guess?.isTv ?? item.isSeries;
    final key = scraperCacheKey(
      tmdbId: null,
      imdbId: item.providerIds['Imdb'] ?? item.providerIds['imdb'],
      name: queryTitle,
      year: queryYear,
      path: filePath,
    );

    // Cached decisions short-circuit before the concurrency gate.
    final cached = ScraperCache.instance.lookup(key);
    if (cached != null) {
      if (!cached.hit || cached.data == null) {
        return ScrapeResult(item: item, applied: false, verdict: 'skip', reason: 'cached-miss');
      }
      // Honour the verdict recorded at scoring time: a "review" candidate must
      // never be silently promoted to an applied poster on a later cache hit.
      if (cached.data!['apply'] != true) {
        return ScrapeResult(
          item: item,
          applied: false,
          verdict: '${cached.data!['verdict'] ?? 'review'}',
          reason: 'cached-review',
        );
      }
      return _apply(item, cached.data!);
    }

    final ongoing = _inFlight[key];
    if (ongoing != null) return ongoing;

    final future = _scrapeRemote(
      item,
      key,
      queryTitle: queryTitle,
      queryYear: queryYear,
      queryIsTv: queryIsTv,
    );
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  /// Convenience for row-level prefetch. Errors are swallowed so scrolling is
  /// never interrupted by a network hiccup.
  Future<void> prefetch(Iterable<EmbyItem> items) async {
    final needed = items.where(needsScrape).toList();
    if (needed.isEmpty) return;
    await Future.wait(
      needed.map((item) => scrape(item).catchError((_) => ScrapeResult(item: item, applied: false, verdict: 'error'))),
    );
  }

  /// True when this item still lacks artwork the scraper could fill: no
  /// provider id yet, no server poster, and nothing applied locally.
  ///
  /// Public because the whole-library scan filters on exactly the same rule as
  /// the row prefetch — two definitions would drift apart.
  bool needsScrape(EmbyItem item) =>
      item.tmdbId == null &&
      (item.primaryImageTag == null || item.primaryImageTag!.isEmpty) &&
      item.localizedPosterPath == null;

  Future<ScrapeResult> _scrapeRemote(
    EmbyItem item,
    String key, {
    required String queryTitle,
    int? queryYear,
    required bool queryIsTv,
  }) async {
    await _gate.acquire();
    try {
      _attempted++;
      final results = await tmdb!.searchMulti(queryTitle, language: language);
      final candidates = <_Candidate>[];
      for (final j in results.take(_maxCandidates)) {
        final c = _Candidate.fromTmdb(j);
        if (c != null) candidates.add(c);
      }
      if (candidates.isEmpty) {
        ScraperCache.instance.store(key, null);
        notifyListeners();
        return ScrapeResult(item: item, applied: false, verdict: 'skip', reason: 'no-candidates');
      }

      final scorer = const MatchScorer();
      final scored = <({_Candidate candidate, MatchScore score})>[];
      for (final c in candidates) {
        scored.add((
          candidate: c,
          score: scorer.score(
            queryTitle: queryTitle,
            candidateTitle: c.title,
            candidateOriginal: c.originalTitle,
            queryYear: queryYear,
            candidateYear: c.year,
            queryIsTv: queryIsTv,
            candidateIsTv: c.isTv,
          ),
        ));
      }
      scored.sort((a, b) => b.score.score.compareTo(a.score.score));
      final best = scored.first;
      final second = scored.length > 1 ? scored[1].score.score : null;
      final verdict = scorer.verdict(best.score, secondBest: second);

      final data = <String, dynamic>{
        'verdict': verdict.label,
        // Only an auto verdict may ever be applied, including on cache hits.
        'apply': verdict == MatchVerdict.auto,
        'title': best.candidate.title,
        'year': best.candidate.year,
        'score': best.score.score,
        'reason': best.score.reason,
        if (best.candidate.posterPath != null) 'posterPath': best.candidate.posterPath,
        if (best.candidate.overview != null) 'overview': best.candidate.overview,
      };
      ScraperCache.instance.store(key, data);

      // Only an auto verdict is applied without user confirmation. A review
      // candidate is cached for a future "correct metadata" UI but not shown.
      if (verdict != MatchVerdict.auto) {
        notifyListeners();
        return ScrapeResult(
          item: item,
          applied: false,
          verdict: verdict.label,
          reason: best.score.reason,
        );
      }

      final result = _apply(item, data);
      if (result.applied) _applied++;
      notifyListeners();
      return result;
    } catch (e) {
      debugPrint('[scraper] scrape "$queryTitle" failed: $e');
      return ScrapeResult(item: item, applied: false, verdict: 'error', reason: '$e');
    } finally {
      _gate.release();
    }
  }

  ScrapeResult _apply(EmbyItem item, Map<String, dynamic> data) {
    final poster = data['posterPath'] as String?;
    final overview = data['overview'] as String?;
    final hasPoster = poster != null && poster.isNotEmpty;
    final hasOverview = overview != null && overview.isNotEmpty;
    if (!hasPoster && !hasOverview) {
      return ScrapeResult(item: item, applied: false, verdict: data['verdict'] ?? 'skip', reason: 'empty-data');
    }
    final updated = item.copyWith(
      localizedPosterPath: hasPoster ? poster : null,
      overview: hasOverview && (item.overview == null || item.overview!.isEmpty) ? overview : null,
    );
    return ScrapeResult(item: updated, applied: true, verdict: data['verdict'] ?? 'auto');
  }

  static String? _sourcePath(EmbyItem item) {
    for (final source in item.mediaSources) {
      final p = source.path;
      if (p != null && p.isNotEmpty) return p;
    }
    return null;
  }

  static String _basename(String path) {
    var s = path.replaceAll('\\', '/');
    final slash = s.lastIndexOf('/');
    if (slash >= 0) s = s.substring(slash + 1);
    return s;
  }

  /// Clears every local scraper decision. Call from a "reset cache" action.
  Future<void> clearCache() async {
    await ScraperCache.instance.clear();
    _applied = 0;
    _attempted = 0;
    notifyListeners();
  }

  /// Re-queries TMDB and returns the ranked candidates for [item].
  ///
  /// Used by the detail page's "correct metadata" panel: the automatic path
  /// refuses to apply anything below the auto threshold, so the user needs a way
  /// to see and pick what the scraper found. Returns an empty list on any
  /// failure — the caller shows "nothing found" rather than an error.
  Future<List<ScrapeCandidate>> candidates(EmbyItem item, {int limit = 5}) async {
    if (tmdb == null) return const [];
    final filePath = _sourcePath(item);
    final guess = filePath == null ? null : const FilenameGuesser().guess(_basename(filePath));
    final queryTitle = (guess?.title.isNotEmpty ?? false) ? guess!.title : item.name.trim();
    if (queryTitle.isEmpty) return const [];
    final queryYear = guess?.year ?? item.productionYear;
    final queryIsTv = guess?.isTv ?? item.isSeries;

    await _gate.acquire();
    try {
      final results = await tmdb!.searchMulti(queryTitle, language: language);
      final scorer = const MatchScorer();
      final scored = <ScrapeCandidate>[];
      for (final j in results.take(limit)) {
        final c = _Candidate.fromTmdb(j);
        if (c == null) continue;
        final score = scorer.score(
          queryTitle: queryTitle,
          candidateTitle: c.title,
          candidateOriginal: c.originalTitle,
          queryYear: queryYear,
          candidateYear: c.year,
          queryIsTv: queryIsTv,
          candidateIsTv: c.isTv,
        );
        scored.add(ScrapeCandidate(
          title: c.title,
          year: c.year,
          posterPath: c.posterPath,
          overview: c.overview,
          isTv: c.isTv,
          score: score.score,
          verdict: scorer.verdict(score).label,
        ));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
      return scored;
    } catch (e) {
      debugPrint('[scraper] candidates for "$queryTitle" failed: $e');
      return const [];
    } finally {
      _gate.release();
    }
  }

  /// Applies a user-chosen candidate and caches the decision as authoritative,
  /// so later cache hits keep showing it instead of re-scoring.
  ScrapeResult applyCandidate(EmbyItem item, ScrapeCandidate choice) {
    final filePath = _sourcePath(item);
    final key = scraperCacheKey(
      tmdbId: null,
      imdbId: item.providerIds['Imdb'] ?? item.providerIds['imdb'],
      name: choice.title,
      year: choice.year,
      path: filePath,
    );
    final data = <String, dynamic>{
      'verdict': 'user',
      'apply': true,
      'title': choice.title,
      if (choice.year != null) 'year': choice.year,
      'score': choice.score,
      'reason': 'user-selected',
      if (choice.posterPath != null) 'posterPath': choice.posterPath,
      if (choice.overview != null) 'overview': choice.overview,
    };
    ScraperCache.instance.store(key, data);
    final result = _apply(item, data);
    if (result.applied) _applied++;
    notifyListeners();
    return result;
  }
}

/// One TMDB candidate offered to the user in the "correct metadata" panel.
final class ScrapeCandidate {
  const ScrapeCandidate({
    required this.title,
    required this.isTv,
    required this.score,
    required this.verdict,
    this.year,
    this.posterPath,
    this.overview,
  });

  final String title;
  final int? year;
  final String? posterPath;
  final String? overview;
  final bool isTv;
  final double score;
  final String verdict;

  String get label => year == null ? title : '$title ($year)';
}

final class _Candidate {
  const _Candidate({
    required this.title,
    this.originalTitle,
    this.year,
    this.posterPath,
    this.overview,
    required this.isTv,
  });

  final String title;
  final String? originalTitle;
  final int? year;
  final String? posterPath;
  final String? overview;
  final bool isTv;

  static _Candidate? fromTmdb(Map<String, dynamic> j) {
    if ((j['id'] as num?)?.toInt() == null) return null;
    final mediaType = j['media_type'] as String?;
    final isTv = mediaType == 'tv' ||
        (mediaType == null && (j['name'] != null || j['first_air_date'] != null));
    final title = (j['title'] ?? j['name'] ?? '') as String;
    if (title.isEmpty) return null;
    final date = (j['release_date'] ?? j['first_air_date']) as String?;
    return _Candidate(
      title: title,
      originalTitle: (j['original_title'] ?? j['original_name']) as String?,
      year: date != null && date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      posterPath: j['poster_path'] as String?,
      overview: (j['overview'] as String?)?.trim().isEmpty ?? true ? null : j['overview'] as String?,
      isTv: isTv,
    );
  }
}
