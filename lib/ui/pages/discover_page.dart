import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../data/discovery_feed.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import 'routes.dart';

/// Discover centre — a *real*, endlessly paged feed of TMDB / Seerr titles.
///
/// Every card here is a SeerrMedia rendered in the "request" style. Nothing is
/// mapped back to a local EmbyItem, so discovery content never looks owned or
/// playable. The user's library shelves live exclusively on the Home page.
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  AppServices? _services;
  DiscoverySource? _source;
  final Map<DiscoveryCategory, DiscoveryFeed> _feeds = {};
  DiscoveryCategory _selected = DiscoveryCategory.todayPicks;
  final _grid = RevealController(mode: RevealMode.minimal, margin: 120);

  DiscoveryFeed get _feed => _feeds.putIfAbsent(
        _selected,
        () => DiscoveryFeed(
          _selected,
          (category, {required int page}) => _source!.fetch(category, page: page),
        ),
      );

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
    // Kick off the first page for the initial category.
    _loadMore();
  }

  @override
  void dispose() {
    _grid.removeListener(_onScroll);
    _grid.dispose();
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
    if (mounted && feed.items.length != before) setState(() {});
  }

  void _select(DiscoveryCategory category) {
    if (category == _selected) return;
    setState(() => _selected = category);
    if (_grid.hasClients) _grid.jumpTo(0);
    if (_feed.items.isEmpty) _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = _source!;
    final feed = _feed;
    final cards = feed.items.toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: contentLeft, top: 64, right: 120, bottom: 18),
        child: Row(children: [
          Text(l10n.discover, style: Zt.headline),
          const SizedBox(width: 18),
          Text(l10n.discoverySubtitle, style: Zt.label.copyWith(color: Zc.textMuted)),
        ]),
      ),
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
                    padding: const EdgeInsets.fromLTRB(contentLeft, 16, 120, 160),
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
                          builder: (context, cell) => RequestPosterCard(
                            media: m,
                            width: cell.maxWidth,
                            autofocus: i == 0,
                            onSelect: () => openRequest(context, m),
                          ),
                        ),
                      );
                    },
                  ),
                );
              }),
      ),
    ]);
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
