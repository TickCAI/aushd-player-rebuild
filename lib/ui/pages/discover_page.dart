import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/emby/models/emby_item.dart';
import '../../data/discovery_feed.dart';
import '../../data/seerr_api.dart';
import '../../l10n/l10n.dart';
import '../core/playback_launcher.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import 'routes.dart';

/// Discover centre — a *real*, endlessly paged feed of TMDB / Seerr titles.
///
/// Cards here are TMDB results, never local EmbyItems. Each card checks the
/// user's imported library by TMDB id: a match plays immediately, otherwise
/// the title can be added to the local "watch later" (待播) list. Discovery
/// content therefore never masquerades as owned media.
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  AppServices? _services;
  DiscoverySource? _source;
  final Map<String, DiscoveryFeed> _feeds = {};
  DiscoveryCategory _selected = DiscoveryCategory.todayPicks;
  final _grid = RevealController(mode: RevealMode.minimal, margin: 120);

  // Search / filter state.
  final _searchController = TextEditingController();
  String _query = '';
  DiscoveryFilters _filters = const DiscoveryFilters();

  // Library match + watchlist state, keyed by SeerrMedia.key.
  final Map<String, EmbyItem> _owned = {};
  bool _checkingLibrary = false;

  DiscoveryFeed get _feed => _feeds.putIfAbsent(
        _feedKey,
        () => DiscoveryFeed(
          _selected,
          (category, {required int page}) {
            final q = _query.trim();
            final src = _source!;
            return q.isNotEmpty
                ? src.search(q, page: page, filters: _filters)
                : src.fetch(category, page: page, filters: _filters);
          },
        ),
      );

  /// A filter / query change starts a brand-new feed so stale pages fetched
  /// under different criteria are never shown.
  String get _feedKey => '${_selected.id}|${_query.trim()}|${_filters.signature}';

  @override
  void initState() {
    super.initState();
    _grid.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services != null) return;
    final s = AppServicesScope.read(context);
    _services = s;
    _source = DiscoverySource(tmdb: s.tmdb, seerr: s.seerr, language: s.recommender.language);
    _loadMore();
  }

  @override
  void dispose() {
    _grid.removeListener(_onScroll);
    _grid.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_grid.hasClients || !mounted) return;
    final pos = _grid.position;
    // maxScrollExtent <= 0 means the page is not scrollable yet; do not spin.
    if (pos.maxScrollExtent <= 0) return;
    if (pos.pixels >= pos.maxScrollExtent - 600) _loadMore();
  }

  Future<void> _loadMore() async {
    final source = _source;
    if (source == null || !source.available) return;
    final feed = _feed;
    final before = feed.items.length;
    await feed.loadMore();
    if (!mounted) return;
    if (feed.items.length != before) {
      setState(() {});
      _checkLibrary();
    }
  }

  /// Match the currently loaded TMDB titles against the imported library by
  /// TMDB id. A single batched catalog query handles the whole page.
  Future<void> _checkLibrary() async {
    final s = _services;
    if (s == null || _checkingLibrary) return;
    _checkingLibrary = true;
    try {
      final items = _feed.items;
      if (items.isEmpty) return;
      final resolved = await s.recommender.resolve(items);
      if (!mounted) return;
      final owned = <String, EmbyItem>{};
      for (var i = 0; i < resolved.length && i < items.length; i++) {
        final r = resolved[i];
        if (r is EmbyItem) owned[items[i].key] = r;
      }
      setState(() => _owned
        ..clear()
        ..addAll(owned));
    } catch (e) {
      debugPrint('[discovery] library match failed: $e');
    } finally {
      _checkingLibrary = false;
    }
  }

  void _resetFeed() {
    _feeds.remove(_feedKey);
    if (_grid.hasClients) _grid.jumpTo(0);
    setState(() {});
    _loadMore();
  }

  void _select(DiscoveryCategory category) {
    if (category == _selected) return;
    setState(() => _selected = category);
    if (_grid.hasClients) _grid.jumpTo(0);
    if (_feed.items.isEmpty) {
      _loadMore();
    } else {
      _checkLibrary();
    }
  }

  void _onSearchChanged(String text) {
    _query = text;
    _resetFeed();
  }

  void _cycleMediaType() {
    final next = switch (_filters.mediaType) {
      FilterMediaType.all => FilterMediaType.movie,
      FilterMediaType.movie => FilterMediaType.tv,
      FilterMediaType.tv => FilterMediaType.all,
    };
    setState(() => _filters = DiscoveryFilters(
          mediaType: next,
          sort: _filters.sort,
          yearFrom: _filters.yearFrom,
          yearTo: _filters.yearTo,
          genre: _filters.genre,
        ));
    _resetFeed();
  }

  void _cycleSort() {
    final next = switch (_filters.sort) {
      FilterSort.hot => FilterSort.rating,
      FilterSort.rating => FilterSort.latest,
      FilterSort.latest => FilterSort.hot,
    };
    setState(() => _filters = DiscoveryFilters(
          mediaType: _filters.mediaType,
          sort: next,
          yearFrom: _filters.yearFrom,
          yearTo: _filters.yearTo,
          genre: _filters.genre,
        ));
    _resetFeed();
  }

  void _cycleYear() {
    final opts = DiscoveryFilters.yearOptions;
    var idx = opts.indexWhere((o) => o.$1 == _filters.yearFrom && o.$2 == _filters.yearTo);
    if (idx < 0) idx = 0;
    final next = opts[(idx + 1) % opts.length];
    setState(() => _filters = DiscoveryFilters(
          mediaType: _filters.mediaType,
          sort: _filters.sort,
          yearFrom: next.$1,
          yearTo: next.$2,
          genre: _filters.genre,
        ));
    _resetFeed();
  }

  void _cycleGenre() {
    final opts = DiscoveryFilters.genreOptions;
    var idx = opts.indexWhere((o) => o.$1 == (_filters.genre ?? 0));
    if (idx < 0) idx = 0;
    final next = opts[(idx + 1) % opts.length];
    setState(() => _filters = DiscoveryFilters(
          mediaType: _filters.mediaType,
          sort: _filters.sort,
          yearFrom: _filters.yearFrom,
          yearTo: _filters.yearTo,
          genre: next.$1,
        ));
    _resetFeed();
  }

  void _clearFilters() {
    setState(() => _filters = const DiscoveryFilters());
    _resetFeed();
  }

  Future<void> _toggleWatch(SeerrMedia m) async {
    final s = _services!;
    if (!s.profiles.available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.discoveryNoWatchlist)));
      }
      return;
    }
    await s.profiles.toggle(m);
    if (mounted) setState(() {});
  }

  void _openCard(SeerrMedia m) {
    final item = _owned[m.key];
    if (item != null) {
      playItem(context, item);
    } else {
      _toggleWatch(m);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = _source!;
    final feed = _feed;
    final cards = feed.items.toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header row — single, unclipped top padding, no overlap with chips.
      Padding(
        padding: const EdgeInsets.only(left: contentLeft, top: 28, right: 120, bottom: 6),
        child: Row(children: [
          Text(l10n.discover, style: Zt.headline),
          const SizedBox(width: 18),
          Flexible(child: Text(l10n.discoverySubtitle, style: Zt.label.copyWith(color: Zc.textMuted))),
        ]),
      ),
      // Search + filter row.
      Padding(
        padding: const EdgeInsets.only(left: contentLeft, right: 120, bottom: 10),
        child: Row(children: [
          SizedBox(
            width: 360,
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              style: Zt.body,
              decoration: InputDecoration(
                hintText: l10n.discoverySearchHint,
                hintStyle: Zt.body.copyWith(color: Zc.textFaint),
                prefixIcon: const Icon(Icons.search_rounded, color: Zc.textMuted),
                filled: true,
                fillColor: Zc.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 14),
          _filterChip(_mediaTypeLabel(l10n), _cycleMediaType),
          const SizedBox(width: 10),
          _filterChip(_sortLabel(l10n), _cycleSort),
          const SizedBox(width: 10),
          _filterChip(_yearLabel(l10n), _cycleYear),
          const SizedBox(width: 10),
          _filterChip(_genreLabel(l10n), _cycleGenre),
          if (_filters.isActive) ...[
            const SizedBox(width: 10),
            _filterChip(l10n.discoveryClearFilters, _clearFilters),
          ],
        ]),
      ),
      // Category chips.
      Padding(
        padding: const EdgeInsets.only(left: contentLeft, bottom: 12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final c in DiscoveryCategory.values) _chip(c, l10n),
          ]),
        ),
      ),
      Expanded(
        child: !source.available
            ? Padding(
                padding: const EdgeInsets.only(left: contentLeft, top: 40, right: 120),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Text(l10n.discoveryNoSource, style: Zt.body),
                ),
              )
            : LayoutBuilder(builder: (context, box) {
                final columns = _services!.settings.posterSize.columns;
                final cardW = posterGridCardWidth(box.maxWidth, columns);
                return FocusZone(
                  debugLabel: 'discovery-grid:${_selected.id}',
                  child: GridView.builder(
                    controller: _grid,
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.fromLTRB(contentLeft, 8, 120, 160),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 26,
                      crossAxisSpacing: Zs.cardGap,
                      childAspectRatio: cardW / (cardW * 1.5 + 70),
                    ),
                    itemCount: cards.length + 1,
                    itemBuilder: (context, i) {
                      if (i >= cards.length) return _loadMoreCell(cardW, l10n);
                      final m = cards[i];
                      return Align(
                        alignment: Alignment.topLeft,
                        child: LayoutBuilder(
                          builder: (context, cell) => _discoveryCard(m, cell.maxWidth, l10n, i == 0),
                        ),
                      );
                    },
                  ),
                );
              }),
      ),
    ]);
  }

  Widget _discoveryCard(SeerrMedia m, double width, L10n l10n, bool autofocus) {
    final item = _owned[m.key];
    final inList = _services!.profiles.inList(m);
    final (label, icon, color) = item != null
        ? (l10n.discoveryPlay, Icons.play_arrow_rounded, Zc.success)
        : inList
            ? (l10n.discoveryInWatchlist, Icons.check_circle_rounded, Zc.textMuted)
            : (l10n.discoveryWatchLater, Icons.bookmark_border_rounded, Zc.request);
    return RequestPosterCard(
      media: m,
      width: width,
      autofocus: autofocus,
      statusLabel: label,
      statusIcon: icon,
      statusColor: color,
      onSelect: () => _openCard(m),
    );
  }

  String _mediaTypeLabel(L10n l10n) => switch (_filters.mediaType) {
        FilterMediaType.all => l10n.discoveryFilterAll,
        FilterMediaType.movie => l10n.discoveryFilterMovie,
        FilterMediaType.tv => l10n.discoveryFilterTv,
      };

  String _sortLabel(L10n l10n) => switch (_filters.sort) {
        FilterSort.hot => l10n.discoverySortHot,
        FilterSort.rating => l10n.discoverySortRating,
        FilterSort.latest => l10n.discoverySortLatest,
      };

  String _yearLabel(L10n l10n) {
    final o = DiscoveryFilters.yearOptions.firstWhere(
      (e) => e.$1 == _filters.yearFrom && e.$2 == _filters.yearTo,
      orElse: () => DiscoveryFilters.yearOptions.first,
    );
    return switch (o.$3) {
      'All' => l10n.discoveryFilterAll,
      'Y2020s' => l10n.discoveryYear2020,
      'Y2010s' => l10n.discoveryYear2010,
      'Y2000s' => l10n.discoveryYear2000,
      _ => l10n.discoveryYearOld,
    };
  }

  String _genreLabel(L10n l10n) {
    final id = _filters.genre ?? 0;
    return switch (id) {
      0 => l10n.discoveryFilterAll,
      28 => l10n.discoveryGenreAction,
      35 => l10n.discoveryGenreComedy,
      878 => l10n.discoveryGenreSciFi,
      16 => l10n.discoveryGenreAnimation,
      9648 => l10n.discoveryGenreMystery,
      _ => l10n.discoveryGenreHorror,
    };
  }

  Widget _filterChip(String label, VoidCallback onSelect) {
    return TvFocusable(
      onSelect: onSelect,
      builder: (context, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: focused ? Zc.surface : Zc.background,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: focused ? Zc.request : Zc.outline),
        ),
        child: Text(label, style: Zt.label.copyWith(color: focused ? Zc.text : Zc.textMuted)),
      ),
    );
  }

  Widget _chip(DiscoveryCategory category, L10n l10n) {
    final selected = category == _selected;
    final label = switch (category) {
      DiscoveryCategory.todayPicks => l10n.discoveryToday,
      DiscoveryCategory.nowPlaying => l10n.discoveryNowPlaying,
      DiscoveryCategory.comingSoon => l10n.comingSoon,
      DiscoveryCategory.trending => l10n.discoveryTrending,
      DiscoveryCategory.topRated => l10n.topRatedMovies,
      DiscoveryCategory.popularShows => l10n.popularShows,
      DiscoveryCategory.animation => l10n.discoveryAnimation,
    };
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: TvFocusable(
        onSelect: () => _select(category),
        builder: (context, focused) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Zc.request : (focused ? Zc.surface : Zc.background),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected || focused ? Zc.request : Zc.outline),
          ),
          child: Text(
            label,
            style: Zt.label.copyWith(color: selected ? Zc.background : Zc.text, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }

  Widget _loadMoreCell(double cardW, L10n l10n) {
    final feed = _feed;
    if (feed.isLoading) {
      return Align(
        alignment: Alignment.topLeft,
        child: SkeletonBox(width: cardW, height: cardW * 1.5),
      );
    }
    if (!feed.hasMore) {
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: cardW,
          height: cardW * 1.5,
          child: Center(
            child: Text(l10n.discoveryNoMore, style: Zt.label.copyWith(color: Zc.textFaint)),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: TvFocusable(
        onSelect: _loadMore,
        builder: (context, focused) => Container(
          width: cardW,
          height: cardW * 1.5,
          decoration: BoxDecoration(
            color: focused ? Zc.surface : Zc.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: focused ? Zc.request : Zc.outline, width: 2),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.expand_more_rounded, size: 48, color: Zc.textMuted),
            const SizedBox(height: 12),
            Text(l10n.discoveryLoadMore, style: Zt.label.copyWith(color: Zc.textMuted)),
          ]),
        ),
      ),
    );
  }
}
