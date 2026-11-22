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

// ────────────────────────────────────────────────────────────────────────────
// Search / filter model
// ────────────────────────────────────────────────────────────────────────────

enum FilterMediaType { all, movie, tv }

enum FilterSort { hot, rating, latest }

/// Immutable filter selection applied on top of any discovery query.
///
/// Kept in the data layer (no Flutter/l10n dependency) so it can be unit
/// tested and used as a stable cache-key signature.
final class DiscoveryFilters {
  const DiscoveryFilters({
    this.mediaType = FilterMediaType.all,
    this.sort = FilterSort.hot,
    this.yearFrom,
    this.yearTo,
    this.genre,
    this.region,
  });

  final FilterMediaType mediaType;
  final FilterSort sort;
  final int? yearFrom;
  final int? yearTo;

  /// TMDB genre id (0 == any). See [genreOptions].
  final int? genre;

  /// TMDB original-language code (e.g. `zh`, `en`, `ja`), or null for any
  /// region. Serves as the discovery page's "地区" (region) dimension: TMDB's
  /// discover endpoint filters it server-side via `with_original_language`,
  /// and search results / Seerr fallbacks are filtered client-side.
  final String? region;

  bool get isActive => mediaType != FilterMediaType.all ||
      sort != FilterSort.hot ||
      yearFrom != null ||
      yearTo != null ||
      (genre != null && genre != 0) ||
      (region != null && region!.isNotEmpty);

  /// Stable key so a filter change gets a fresh feed instead of reusing pages
  /// fetched under different criteria.
  String get signature => '${mediaType.name}|${sort.name}|$yearFrom|$yearTo|$genre|$region';

  /// TMDB genre ids with an l10n suffix, listed in the filter panel. Covers
  /// the common movie + TV genres so "影片分类" is a real, detailed list.
  static const genreOptions = <(int, String)>[
    (0, 'All'),
    (28, 'Action'),
    (12, 'Adventure'),
    (16, 'Animation'),
    (35, 'Comedy'),
    (80, 'Crime'),
    (99, 'Documentary'),
    (18, 'Drama'),
    (14, 'Fantasy'),
    (36, 'History'),
    (27, 'Horror'),
    (10751, 'Family'),
    (10402, 'Music'),
    (9648, 'Mystery'),
    (10749, 'Romance'),
    (878, 'SciFi'),
    (53, 'Thriller'),
    (10752, 'War'),
    (37, 'Western'),
  ];

  /// (from, to, l10n suffix) triples for the year filter list.
  static const yearOptions = <(int?, int?, String)>[
    (null, null, 'All'),
    (2020, null, 'Y2020s'),
    (2010, 2019, 'Y2010s'),
    (2000, 2009, 'Y2000s'),
    (null, 1999, 'YOld'),
  ];

  /// (language code, l10n suffix) pairs for the "地区" (region) filter list.
  /// TMDB treats this as the original language of a title.
  static const regionOptions = <(String?, String)>[
    (null, 'All'),
    ('zh', 'Chinese'),
    ('en', 'English'),
    ('ja', 'Japanese'),
    ('ko', 'Korean'),
    ('fr', 'French'),
    ('de', 'German'),
    ('es', 'Spanish'),
    ('it', 'Italian'),
    ('ru', 'Russian'),
    ('th', 'Thai'),
    ('hi', 'Hindi'),
  ];
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

  /// Fetch one page. When [filters] is active the category query is replaced
  /// by a single, filter-aware TMDB discover call so all filter dimensions
  /// (type / sort / year / genre / region) behave consistently across every
  /// category.
  Future<List<SeerrMedia>> fetch(DiscoveryCategory category, {
    required int page,
    DiscoveryFilters? filters,
  }) async {
    final f = filters;
    if (f != null && f.isActive) {
      return _withStatuses(await _filteredDiscover(f, page));
    }
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

  /// Real TMDB (or Seerr) multi-search with the same filters applied client
  /// side, so searching obeys the active type / sort / year / genre selection.
  Future<List<SeerrMedia>> search(String query, {
    required int page,
    DiscoveryFilters? filters,
  }) async {
    final t = tmdb;
    final raw = t != null
        ? [for (final r in await t.searchMulti(query, page: page, language: language)) ?SeerrMedia.fromTmdb(r)]
        : await seerr?.search(query) ?? const <SeerrMedia>[];
    return _withStatuses(_applyFilters(raw, filters));
  }

  Future<List<SeerrMedia>> _filteredDiscover(DiscoveryFilters f, int page) async {
    final tv = f.mediaType == FilterMediaType.tv;
    final extra = <String, String>{};
    final yearKey = tv ? 'first_air_date' : 'release_date';
    if (f.yearFrom != null) extra['$yearKey.gte'] = '${f.yearFrom}-01-01';
    if (f.yearTo != null) extra['$yearKey.lte'] = '${f.yearTo}-12-31';
    if (f.genre != null && f.genre! > 0) extra['with_genres'] = '${f.genre}';
    if (f.region != null && f.region!.isNotEmpty) extra['with_original_language'] = f.region!;
    final sortBy = switch (f.sort) {
      FilterSort.rating => 'vote_average.desc',
      FilterSort.latest => '$yearKey.desc',
      FilterSort.hot => 'popularity.desc',
    };
    return _discover(
      tv ? SeerrMediaType.tv : SeerrMediaType.movie,
      page,
      sortBy: sortBy,
      voteCountGte: f.sort == FilterSort.rating ? 100 : null,
      extra: extra,
    );
  }

  /// Client-side filter used for search results and Seerr fallbacks (which
  /// cannot express with_genres / year ranges server-side).
  List<SeerrMedia> _applyFilters(List<SeerrMedia> list, DiscoveryFilters? f) {
    if (f == null || !f.isActive) return list;
    return [
      for (final m in list)
        if ((f.mediaType == FilterMediaType.all ||
                (f.mediaType == FilterMediaType.movie) == !m.isTv) &&
            (f.genre == null || f.genre == 0 || m.genreIds.contains(f.genre)) &&
            (f.yearFrom == null || (m.year ?? 0) >= f.yearFrom!) &&
            (f.yearTo == null || (m.year ?? 9999) <= f.yearTo!) &&
            (f.region == null ||
                f.region!.isEmpty ||
                (m.originalLanguage?.isNotEmpty == true && m.originalLanguage == f.region)))
          m,
    ];
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

  /// Enrich with Seerr request status so cards show live availability.
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
