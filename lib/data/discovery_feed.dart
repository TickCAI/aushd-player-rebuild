import 'dart:developer' as developer;

import 'seerr_api.dart';
import 'tmdb_api.dart';

/// The discovery centre's categories. Each one is a *distinct real* TMDB /
/// Seerr query — not a re-slice of the local library — so "discover" content
/// stays visually and semantically separate from owned (EmbyItem) content.
enum DiscoveryCategory {
  todayPicks,
  nowPlaying,
  comingSoon,
  trending,
  topRated,
  popularShows,
  animation;

  /// Stable id used for cache keys and analytics-style labels.
  String get id => name;

  /// l10n lookup key (resolved in the UI layer; the data layer stays pure).
  String get l10nKey => switch (this) {
        todayPicks => 'discoveryToday',
        nowPlaying => 'discoveryNowPlaying',
        comingSoon => 'discoveryComingSoon',
        trending => 'discoveryTrending',
        topRated => 'discoveryTopRated',
        popularShows => 'discoveryShows',
        animation => 'discoveryAnimation',
      };
}

/// Fetches one page of real discovery results for a category.
///
/// Results are always `SeerrMedia` (TMDB metadata + Seerr request status) and
/// are never mapped back to local EmbyItem — that mapping is what previously
/// made discovered titles look like they were already owned/playable.
final class DiscoverySource {
  DiscoverySource({
    required this.tmdb,
    required this.seerr,
    this.language = TmdbApi.defaultLanguage,
  });

  final TmdbApi? tmdb;
  final SeerrApi? seerr;
  final String language;

  bool get available => tmdb != null || seerr != null;

  Future<List<SeerrMedia>> fetch(DiscoveryCategory category, {required int page}) async {
    final list = switch (category) {
      DiscoveryCategory.todayPicks => await _trending(page, 'day'),
      DiscoveryCategory.trending => await _trending(page, 'week'),
      DiscoveryCategory.comingSoon => await _upcoming(page),
      DiscoveryCategory.nowPlaying => await _discover(
          SeerrMediaType.movie, page, sortBy: 'popularity.desc', extra: const {'with_release_type': '2|3'}),
      DiscoveryCategory.topRated => await _discover(
          SeerrMediaType.movie, page, sortBy: 'vote_average.desc', voteCountGte: 3000),
      DiscoveryCategory.popularShows => await _discover(SeerrMediaType.tv, page, sortBy: 'popularity.desc'),
      DiscoveryCategory.animation => await _discover(
          SeerrMediaType.movie, page, sortBy: 'popularity.desc', extra: const {'with_genres': '16'}),
    };
    return _withStatuses(list);
  }

  Future<List<SeerrMedia>> _trending(int page, String window) async {
    final t = tmdb;
    if (t != null) {
      final raw = await t.list('/trending/all/$window', page: page, language: language);
      return [for (final r in raw) ?SeerrMedia.fromTmdb(r)];
    }
    final s = seerr;
    if (s != null) return s.trending(page: page, timeWindow: window);
    return const [];
  }

  Future<List<SeerrMedia>> _upcoming(int page) async {
    final t = tmdb;
    if (t != null) {
      final raw = await t.list('/movie/upcoming', page: page, language: language);
      return [for (final r in raw) ?SeerrMedia.fromTmdb(r, type: SeerrMediaType.movie)];
    }
    final s = seerr;
    if (s != null) return s.upcomingMovies(page: page);
    return const [];
  }

  Future<List<SeerrMedia>> _discover(
    SeerrMediaType type,
    int page, {
    String? sortBy,
    int? voteCountGte,
    Map<String, String> extra = const {},
  }) async {
    final t = tmdb;
    if (t != null) {
      final raw = await t.discover(
        type == SeerrMediaType.tv,
        page: page,
        language: language,
        sortBy: sortBy,
        voteCountGte: voteCountGte,
        extra: extra,
      );
      return [for (final r in raw) ?SeerrMedia.fromTmdb(r, type: type)];
    }
    final s = seerr;
    if (s != null) {
      // Seerr's discover endpoint has no with_genres / with_release_type
      // filter; those two categories degrade to its popular feed.
      return s.discover(type, page: page, sortBy: sortBy, voteCountGte: voteCountGte);
    }
    return const [];
  }

  /// Enrich with Seerr request status so cards show "Request / Available / …".
  /// A status lookup failure must never blank the feed.
  Future<List<SeerrMedia>> _withStatuses(List<SeerrMedia> media) async {
    final s = seerr;
    if (s == null || media.isEmpty) return media;
    try {
      final statuses = await s.mediaStatuses();
      return [
        for (final m in media)
          if (statuses[m.key] case final st?) m.withAvailability(st.availability, embyItemId: st.embyItemId) else m,
      ];
    } catch (e) {
      developer.log('[discovery] status lookup failed: $e');
      return media;
    }
  }
}

/// Signature for a page fetcher. DiscoverySource.fetch matches this shape;
/// tests can inject a fake to exercise pagination without any network.
typedef DiscoveryPageFetcher = Future<List<SeerrMedia>> Function(
  DiscoveryCategory category, {
  required int page,
});

/// Pagination + de-duplication state for one discovery category.
///
/// The UI calls [loadMore] when the user reaches the bottom of the grid; each
/// call fetches exactly one page and appends only unseen titles. Stopping is
/// driven by "a page added nothing new" (or an explicit cap), so scrolling can
/// continue for as many pages as the upstream service provides.
final class DiscoveryFeed {
  DiscoveryFeed(this.category, this.fetch);

  final DiscoveryCategory category;
  final DiscoveryPageFetcher fetch;

  final List<SeerrMedia> items = <SeerrMedia>[];
  final Set<String> _seen = <String>{};

  int _page = 0;
  static const _maxPages = 500;
  bool _hasMore = true;
  bool _loading = false;

  bool get hasMore => _hasMore;
  bool get isLoading => _loading;
  int get loadedPage => _page;

  void reset() {
    items.clear();
    _seen.clear();
    _page = 0;
    _hasMore = true;
    _loading = false;
  }

  /// Fetch the next page. Returns the number of newly appended titles.
  /// Concurrent calls are ignored (the scroll listener fires repeatedly).
  Future<int> loadMore() async {
    if (_loading || !_hasMore) return 0;
    _loading = true;
    try {
      final page = await fetch(category, page: _page + 1);
      _page++;
      var added = 0;
      for (final m in page) {
        if (_seen.add(m.key)) {
          items.add(m);
          added++;
        }
      }
      if (added == 0 || _page >= _maxPages) _hasMore = false;
      return added;
    } catch (e) {
      developer.log('[discovery] ${category.id} page ${_page + 1}: $e');
      // A transient failure ends this scroll session; pull-to-refresh (reset)
      // lets the user try again. Do not spin forever on an error page.
      _hasMore = false;
      return 0;
    } finally {
      _loading = false;
    }
  }
}
