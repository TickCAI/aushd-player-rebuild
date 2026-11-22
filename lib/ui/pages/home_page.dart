import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/emby/models/emby_item.dart';
import '../../data/catalog_api.dart';
import '../../data/discovery_feed.dart';
import '../../data/recommendations.dart';
import '../../data/seerr_api.dart';
import '../../data/smart_list.dart';
import '../../data/taste_profile.dart';
import '../../data/title_tags.dart';
import '../../core/log/app_log.dart';
import '../../l10n/content_zh.dart';
import '../../l10n/l10n.dart';
import '../core/artwork.dart';
import '../core/input_mode.dart';
import '../core/playback_launcher.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/backdrop.dart';
import '../widgets/cards.dart';
import '../widgets/cinema_loader.dart';
import '../widgets/library_card.dart';
import '../widgets/media_row.dart';
import '../widgets/mixed_cards.dart';
import '../widgets/mood_shelf.dart';
import '../widgets/trailer.dart';
import 'hero.dart';
import 'title_extras.dart';
import 'routes.dart';

enum _Kind {
  cards,

  continueWatching,
  collections,
  libraries,

  moods,
}

class _Row {
  _Row(this.title, this.load,
      {this.style = CardStyle.poster, this.kind = _Kind.cards, this.recommends = true, this.smartSpec});

  String Function(L10n) title;

  final Future<MixedItems> Function() load;
  final CardStyle style;
  final _Kind kind;

  final bool recommends;

  /// Set for smart-shelf rows so the "More" affordance can open a filtered
  /// library view for the same spec (§3.2).
  final SmartSpec? smartSpec;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onOpenLibraryView, this.onOpenSmartList, this.onOpenDiscover});

  /// Called when a server-library tile on the home page is activated.
  final ValueChanged<LibraryView>? onOpenLibraryView;

  /// Called when a smart-list row's "More" affordance is activated.
  final ValueChanged<SmartSpec>? onOpenSmartList;

  /// Called when the "Discover" entry is activated. Discovery content lives in
  /// its own page (real TMDB/Seerr feed), kept separate from library rows.
  final VoidCallback? onOpenDiscover;

  static final firstLoad = ValueNotifier(true);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _hero = Debounced<HeroInfo?>(null);
  final _scroll = RevealController(mode: RevealMode.anchored, anchor: 64);
  List<_Row>? _rows;
  final _data = <_Row, Future<MixedItems>>{};

  final _allowed = <_Row>{};
  int _loading = 0;
  static const _parallelRows = 3;

  final _resolved = <_Row, MixedItems>{};
  bool _heroSet = false;

  /// Auto-rotating hero candidates. Only entries with a reachable backdrop
  /// enter the pool, so the carousel never fades to an empty frame.
  final _heroPool = <HeroInfo>[];
  static const _heroPoolLimit = 8;
  static const _heroDwell = Duration(seconds: 7);
  static const _heroPinTime = Duration(seconds: 12);
  int _heroIndex = 0;
  Timer? _carousel;
  Timer? _heroUnpin;
  bool _heroPinned = false;
  bool _animationsEnabled = true;

  bool _loaded = false;
  bool _showLoader = false;

  Future<TasteProfile>? _taste;

  Future<List<TitleTag>>? _tasteTags;

  AppServices? _services;
  String _pickedCollections = '';

  _Row? _myListRow;
  String _myListKeys = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_rows == null) {
      _rows = _buildRows(AppServicesScope.read(context));
      _allowFirstRows();
      _scroll.addListener(_onScroll);
      _awaitFirstRows();
    }
    if (_services == null) {
      _services = AppServicesScope.read(context);
      _services!.libraryChanged.addListener(refresh);
      _services!.profiles.addListener(_onProfile);
      _pickedCollections = _collectionsKey(_services!);
      _services!.addListener(_onServices);
    }
  }

  static List<(String, String)> _collections(AppServices s) =>
      s.isSignedIn ? s.settings.homeCollectionsOf(s.janus.session.userId) : const [];

  static String _collectionsKey(AppServices s) => [for (final (id, _) in _collections(s)) id].join(',');

  void _onServices() {
    final key = _collectionsKey(_services!);
    if (key == _pickedCollections || !mounted) return;
    _pickedCollections = key;
    setState(() {
      _rows = _buildRows(_services!);
      _data.clear();
      _resolved.clear();
      _heroPool.clear();
      _heroSet = false;
      _heroIndex = 0;
      _allowFirstRows();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _pump());
  }

  void _onProfile() {
    final keys = [for (final e in _services!.profiles.profile?.list ?? const []) e.key].join(',');
    if (keys == _myListKeys) return;
    _myListKeys = keys;
    final row = _myListRow;
    if (row != null && mounted) setState(() => _data.remove(row));
  }

  void _allowFirstRows() {
    _allowed
      ..clear()
      ..addAll(_rows!.take(6).where((r) => !r.recommends && r.kind != _Kind.moods));
  }

  void _pump({int upTo = -1}) {
    final rows = _rows!;
    var changed = false;
    for (var i = 0; i < rows.length && i <= upTo; i++) {
      changed |= _allowed.add(rows[i]);
    }
    if (_loaded) {
      for (final r in rows) {
        if (_loading >= _parallelRows) break;
        if (_allowed.add(r)) {
          changed = true;
          if (!_data.containsKey(r)) _loading++;
          _load(r, counted: true);
        }
      }
    }
    if (changed && mounted) setState(() {});
  }

  void _onScroll() {
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final upTo = (offset + MediaQuery.sizeOf(context).height * 2) ~/ 320;
    if (upTo >= 0 && _rows!.take(upTo + 1).any((r) => !_allowed.contains(r))) _pump(upTo: upTo);
  }

  void _awaitFirstRows() {
    if (!AppServicesScope.read(context).isSignedIn) {
      _loaded = true;
      HomePage.firstLoad.value = false;
      return;
    }
    final first = _rows!
        .where((r) => r.kind == _Kind.continueWatching || (r.kind == _Kind.cards && !r.recommends))
        .take(2);
    Timer(const Duration(milliseconds: 400), () {
      if (mounted && !_loaded && AppServicesScope.read(context).isSignedIn) setState(() => _showLoader = true);
    });
    Future.wait(first.map((r) => _load(r).catchError((Object _) => const <Object>[])))
        .timeout(const Duration(seconds: 45), onTimeout: () => const [])
        .whenComplete(() {
      AppLog.mark('home rows loaded');
      HomePage.firstLoad.value = false;
      if (mounted) setState(() => _loaded = true);
      _pump();
    });
  }

  @override
  void dispose() {
    _services?.libraryChanged.removeListener(refresh);
    _services?.profiles.removeListener(_onProfile);
    _services?.removeListener(_onServices);
    _carousel?.cancel();
    _heroUnpin?.cancel();
    _hero.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void refresh() {
    // Smart shelves cache for 30 min; a manual/library refresh must drop it so
    // newly watched items and taste changes are reflected immediately.
    SmartListResolver.invalidate();
    setState(() {
      _data.clear();
      _taste = null;
      _tasteTags = null;
      _heroPool.clear();
      _heroSet = false;
      _heroIndex = 0;
      _allowFirstRows();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _pump());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.wait(_data.values.map((f) => f.catchError((Object _) => const <Object>[]))).whenComplete(() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final focus = FocusManager.instance.primaryFocus;
          if (focus == null || focus.context == null || !focus.context!.mounted) _focusFirstCard();
        });
      });
    });
  }

  void _focusFirstCard() {
    final ctx = context;
    final scope = FocusScope.of(ctx);
    for (final n in scope.descendants) {
      if (n is ZoneScopeNode && n.items.isNotEmpty) {
        ZoneNavigator.enter(n);
        return;
      }
    }
  }

  Future<TasteProfile> _profile(AppServices s) => _taste ??= TasteProfile.load(s.catalog).catchError((Object e) {
        debugPrint('[home] taste profile: $e');
        return const TasteProfile();
      });

  /// Build a row backed by a declarative SmartSpec (§5). Every smart row is
  /// non-recommending by default: these shelves already apply their own
  /// taste/unplayed filters, so the global `keptInRecommendations` gate would
  /// silently drop most of them.
  ///
  /// Discovery content lives in its own space (DiscoverPage) and is never
  /// mixed into these library-backed shelves (§3.1 two-system separation).
  _Row _smartRow(AppServices s, SmartSpec spec, String Function(L10n) title,
      {CardStyle style = CardStyle.poster}) {
    return _Row(title, () async {
      final resolver = SmartListResolver(s.catalog, await _profile(s));
      return resolver.resolve(spec);
    }, style: style, recommends: false, smartSpec: spec);
  }

  /// A home row backed by the *real* discovery feed (TMDB / Seerr), per the
  /// user's redesign: 热门趋势 / 热门剧集 / 本周推荐 / 为你推荐 now pull from
  /// the same source as the Discover page instead of re-slicing the local
  /// library. Titles that exist in the user's library are matched by TMDB id
  /// and become EmbyItems, so a click opens the Emby detail page; the rest
  /// stay SeerrMedia and open the Seerr detail page. Neither plays directly.
  /// When no discovery source is configured the row silently hides itself.
  _Row _discoveryRow(AppServices s, DiscoveryCategory category, String Function(L10n) title,
      {CardStyle style = CardStyle.poster}) {
    return _Row(title, () async {
      final src = DiscoverySource(tmdb: s.tmdb, seerr: s.seerr, language: s.recommender.language);
      if (!src.available) return const <Object>[];
      try {
        final page = await src.fetch(category, page: 1);
        // Map library hits to EmbyItem so their cards open the Emby detail
        // page (matching the Discover page's two-system behaviour).
        return await s.recommender.resolve(page.take(20).toList());
      } catch (e) {
        debugPrint('[home] discovery $category: $e');
        return const <Object>[];
      }
    }, style: style, recommends: false);
  }

  Future<List<TitleTag>> _tags(AppServices s) => _tasteTags ??= () async {
        final tags = s.titleTags;
        if (tags == null) return const <TitleTag>[];
        return tags.taste(await _profile(s));
      }()
          .catchError((Object e) {
        debugPrint('[home] taste tags: $e');
        return const <TitleTag>[];
      });

  /// Real server libraries, with their own artwork and item counts. A failing
  /// /Views call must never wipe out the whole home page or stall its loader.
  static Future<MixedItems> _libraryTiles(AppServices s) async {
    try {
      final views = await s.catalog.viewsWithCounts();
      // Two libraries often resolve to the same server-picked featured still;
      // drop the duplicate so the shelf doesn't repeat a cover.
      return <Object>[for (final v in CatalogApi.dedupeLibraryArtwork(views)) if (v.name.isNotEmpty) v];
    } catch (e) {
      debugPrint('[home] library views: $e');
      return const <Object>[];
    }
  }

  /// BoxSets are named -- and illustrated -- in whatever language the server
  /// stored. A shelf full of Korean/English covers reads as broken on a
  /// Chinese-first home page, so keep only Chinese-named sets here. The
  /// Collections page still shows everything.
  static MixedItems _chineseCollections(List<EmbyItem> items) => <Object>[
        for (final item in items)
          if (ContentZh.hasChinese(item.name)) item,
      ];

  List<_Row> _buildRows(AppServices s) {
    final c = s.catalog;
    Future<MixedItems> items(Future<ItemPage> page) async => (await page).items;

    // Smart shelves that stay library-backed (§3.1 B/C zones). Declarative
    // specs live in `lib/data/smart_list.dart`; a shelf below its minItems is
    // hidden by the resolver, so no empty rows are produced here.
    final smart = <_Row>[
      _smartRow(s, SmartSpec.thisWeek, (l) => l.smartThisWeek,
          style: CardStyle.landscape),
      _smartRow(s, SmartSpec.fresh, (l) => l.smartFresh),
      _smartRow(s, SmartSpec.gems, (l) => l.smartGems),
    ];

    // Six zones (§3.1), ≤12 rows, no duplicate titles. Per the user's
    // redesign, 热门趋势 / 热门剧集 / 本周推荐 / 为你推荐 are now pulled from
    // the real discovery feed (TMDB / Seerr) instead of re-slicing the local
    // library; clicking their cards opens a detail page, never plays directly.
    return [
      // A 续看区
      _Row((l) => l.continueWatching, () => c.continueWatching(), kind: _Kind.continueWatching, recommends: false),
      // D 分类区 (server libraries rendered as aligned landscape tiles)
      _Row((l) => l.myLibraries, () => _libraryTiles(s), kind: _Kind.libraries, style: CardStyle.spotlight, recommends: false),
      // B 更新区
      smart[0], // 本周更新
      _discoveryRow(s, DiscoveryCategory.trending, (l) => l.homeTrending,
          style: CardStyle.ranked), // 热门趋势（本周）
      // C 榜单区
      _discoveryRow(s, DiscoveryCategory.popularShows, (l) => l.homePopularShows,
          style: CardStyle.landscape), // 热门剧集
      smart[1], // 新片速递
      smart[2], // 冷门佳作
      // E 片单区
      _myListRow = _Row((l) => l.myList, s.myList, recommends: false),
      _Row((l) => l.yourFavorites,
          () => items(c.query(types: ['Movie', 'Series'], filters: 'IsFavorite', sortBy: 'Random', limit: 30)),
          style: CardStyle.landscape, recommends: false),
      // F 推荐区 (discovery-backed, sunk to the bottom)
      _discoveryRow(s, DiscoveryCategory.todayPicks, (l) => l.smartPicks,
          style: CardStyle.spotlight), // 本周推荐
      _discoveryRow(s, DiscoveryCategory.trending, (l) => l.recommendedForYou,
          style: CardStyle.poster), // 为你推荐
    ];
  }

  static List<Object> _interleave(List<Object> a, List<Object> b) => [
        for (var i = 0; i < a.length || i < b.length; i++) ...[if (i < a.length) a[i], if (i < b.length) b[i]],
      ];

  _Row _because(AppServices s, List<EmbyItem> Function(TasteProfile) pick, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final seeds = pick(await _profile(s));
      if (seeds.length <= index) return const [];
      final seed = seeds[index];
      row.title = (l) => l.becauseYouWatched(seed.name);
      final seerr = s.seerr;
      final tmdbId = seed.tmdbId;
      final MixedItems items;
      if (seerr != null && tmdbId != null) {
        items = await s.recommender.mixed(
            (p) => seerr.recommendations(tmdbId, seed.isSeries ? SeerrMediaType.tv : SeerrMediaType.movie, page: p),
            pages: 2,
            hidePlayed: true);
      } else {
        items = [for (final i in await s.catalog.similar(seed.id, limit: 24)) if (!i.isPlayed) i];
      }
      return [for (final i in items) if (i is! EmbyItem || i.id != seed.id) i];
    }, style: style);
  }

  _Row _likeTag(AppServices s, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final l10n = context.l10n;
      final said = <String>{};
      final tags = [
        for (final t in await _tags(s))
          if (tagRowTitle(l10n, t) case final title? when said.add(title)) t,
      ];
      if (tags.length <= index) return const [];
      final tag = tags[index];
      row.title = (l) => tagRowTitle(l, tag) ?? tagLabel(l, tag);
      final r = s.recommender;
      final (movies, shows) = await (
        r.tagged(tag, SeerrMediaType.movie, hidePlayed: true),
        r.tagged(tag, SeerrMediaType.tv, hidePlayed: true),
      ).wait;
      final all = _interleave(movies, shows);
      return all.length < 4 ? const [] : all.take(40).toList();
    }, style: style);
  }

  _Row _starring(AppServices s, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final actors = (await _profile(s)).actors;
      if (actors.length <= index) return const [];
      final person = actors[index].person;
      row.title = (l) => l.starring(person.name);
      return _personWork(s, person, types: const ['Movie', 'Series']);
    }, style: style);
  }

  _Row _directedBy(AppServices s, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final directors = (await _profile(s)).directors;
      if (directors.length <= index) return const [];
      final person = directors[index].person;
      row.title = (l) => l.directedBy(person.name);
      return _personWork(s, person, types: const ['Movie'], movieCreditsOnly: true);
    }, style: style);
  }

  static Future<MixedItems> _personWork(AppServices s, Person person,
      {required List<String> types, bool movieCreditsOnly = false}) async {
    final c = s.catalog;
    final seerr = s.seerr;
    final (library, details) = await (
      c.query(personIds: person.id, types: types, filters: 'IsUnplayed', sortBy: 'CommunityRating', descending: true, limit: 40),
      seerr == null ? Future<EmbyItem?>.value() : c.item(person.id).then<EmbyItem?>((v) => v, onError: (Object _) => null),
    ).wait;
    final requestable = <SeerrMedia>[];
    final tmdbId = details?.tmdbId;
    if (seerr != null && tmdbId != null) {
      try {
        final credits = await seerr.personCredits(tmdbId, name: person.name);
        final kept = [
          for (final m in credits)
            if (RecommendationFilter.keep(m) && (m.voteCount ?? 0) >= 50 && (!movieCreditsOnly || !m.isTv)) m,
        ].take(40).toList();
        requestable.addAll((await s.recommender.resolve(kept)).whereType<SeerrMedia>());
      } catch (e) {
        debugPrint('[home] credits of ${person.name}: $e');
      }
    }
    final all = <Object>[...library.items, ...requestable.take(24)];
    return all.length < 4 ? const [] : all;
  }

  _Row _moreGenre(AppServices s, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final genres = (await _profile(s)).genres;
      if (genres.length <= index) return const [];
      final genre = genres[index].genre;
      row.title = (l) => l.moreGenre(lowerFirst(ContentZh.genre(genre)));
      final page = await s.catalog.query(
          types: ['Movie', 'Series'], genres: [genre], filters: 'IsUnplayed', sortBy: 'Random', minCommunityRating: 6.5, limit: 30);
      return page.items;
    }, style: style);
  }

  Future<MixedItems> _load(_Row row, {bool counted = false}) => _data.putIfAbsent(row, () async {
        // Capture everything that needs a BuildContext before the first await.
        final l10n = context.l10n;
        final services = AppServicesScope.read(context);
        if (!counted) _loading++;
        try {
          var items = await row.load();
          if (row.recommends) items = [for (final i in items) if (i.keptInRecommendations) i];
          _resolved[row] = items;
          _collectHero(items, l10n, services);
          return items;
        } finally {
          _loading--;
          scheduleMicrotask(() => mounted ? _pump() : null);
        }
      });

  static HeroInfo? _infoFor(Object data, L10n l10n, AppServices services) {
    if (data is EmbyItem) return HeroInfo.fromItem(l10n, services, data);
    if (data is SeerrMedia) return HeroInfo.fromRequest(l10n, data);
    return null;
  }

  /// Feed resolved rows into the carousel pool. An entry without a backdrop
  /// is skipped so an unreachable TMDB CDN can never produce a blank hero.
  void _collectHero(MixedItems items, L10n l10n, AppServices services) {
    if (_heroPool.length >= _heroPoolLimit) return;
    final keys = {for (final h in _heroPool) h.key};
    for (final data in items) {
      if (_heroPool.length >= _heroPoolLimit) break;
      final info = _infoFor(data, l10n, services);
      if (info == null || info.backdrop == null || !keys.add(info.key)) continue;
      _heroPool.add(info);
    }
    if (!_heroSet && _heroPool.isNotEmpty) {
      _heroSet = true;
      _heroIndex = 0;
      _hero.set(_heroPool.first, immediate: true);
    }
    _syncCarousel();
  }

  void _syncCarousel() {
    final want = _animationsEnabled && mounted && _heroPool.length >= 2;
    if (want == (_carousel != null)) return;
    _carousel?.cancel();
    _carousel = want ? Timer.periodic(_heroDwell, (_) => _advanceHero()) : null;
  }

  void _advanceHero() {
    if (!mounted || _heroPinned || _heroPool.length < 2) return;
    _heroIndex = (_heroIndex + 1) % _heroPool.length;
    _hero.set(_heroPool[_heroIndex]);
  }

  /// A focused card owns the hero for a while: silently rotating the backdrop
  /// while someone is reading a row with a remote is disorienting.
  void _pinHero() {
    _heroPinned = true;
    _heroUnpin?.cancel();
    _heroUnpin = Timer(_heroPinTime, () {
      if (!mounted) return;
      _heroPinned = false;
    });
  }

  void _focusHeroInfo(HeroInfo info) {
    _pinHero();
    for (var i = 0; i < _heroPool.length; i++) {
      if (_heroPool[i].key == info.key) {
        _heroIndex = i;
        break;
      }
    }
    _hero.set(info);
  }

  void _focusData(Object data, {bool immediate = false}) {
    final info = _infoFor(data, context.l10n, AppServicesScope.read(context));
    if (info == null) return;
    _pinHero();
    for (var i = 0; i < _heroPool.length; i++) {
      if (_heroPool[i].key == info.key) {
        _heroIndex = i;
        break;
      }
    }
    _hero.set(info, immediate: immediate);
  }

  Future<void> _play(EmbyItem item) => playItem(context, item);

  @override
  Widget build(BuildContext context) {
    final rows = _rows!;
    final size = MediaQuery.sizeOf(context);
    final height = size.height;
    final heroHeight = (height * 0.42).clamp(260.0, 520.0);
    // Keep the text clear of the artwork on narrow windows instead of the old
    // hard-coded right: 600, which swallowed the whole panel on small screens.
    final rightInset = (size.width * 0.42).clamp(140.0, 600.0);
    final animations = !MediaQuery.of(context).disableAnimations;
    if (animations != _animationsEnabled) {
      _animationsEnabled = animations;
      _syncCarousel();
    }

    return Stack(children: [
      const Positioned.fill(child: ColoredBox(color: Zc.background)),
      // The backdrop parallax-scrolls more slowly than the page and fades out
      // once the first rows have covered it.
      Positioned.fill(
        child: AnimatedBuilder(
          animation: _scroll,
          builder: (context, child) {
            final offset = _scroll.hasClients ? _scroll.offset.clamp(0.0, heroHeight) : 0.0;
            final t = (offset / heroHeight).clamp(0.0, 1.0);
            return Transform.translate(
              offset: Offset(0, -offset * 0.35),
              child: Opacity(opacity: 1 - t * 0.92, child: child),
            );
          },
          child: RepaintBoundary(
            child: ValueListenableBuilder<HeroInfo?>(
              valueListenable: _hero,
              builder: (_, info, _) => Backdrop(url: info?.backdrop),
            ),
          ),
        ),
      ),
      // Hero and rows share ONE scroll view, so scrolling really does move the
      // hero off screen. Previously only the lower half of the window scrolled
      // while the hero stayed pinned on top.
      Positioned.fill(
        child: CardTrailers(
          child: SingleChildScrollView(
            controller: _scroll,
            child: ValueListenableBuilder<bool>(
              valueListenable: InputMode.pointer,
              builder: (context, pointer, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedBuilder(
                    animation: _scroll,
                    builder: (context, child) {
                      final offset = _scroll.hasClients ? _scroll.offset.clamp(0.0, heroHeight) : 0.0;
                      final t = (offset / heroHeight).clamp(0.0, 1.0);
                      return Opacity(opacity: 1 - t, child: child);
                    },
                    child: SizedBox(
                      height: heroHeight,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: EdgeInsets.only(left: contentLeft, right: rightInset, bottom: 28),
                          child: ValueListenableBuilder<HeroInfo?>(
                            valueListenable: _hero,
                            builder: (_, info, _) => info == null ? const _HeroSkeleton() : HeroPanel(info: info),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(top: 24, bottom: pointer ? 60 : height * 0.5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, row) in rows.indexed) _buildRow(row, first: i == 0),
                        // Visual break: the discovery feed is a separate system
                        // (request-style SeerrMedia, never owned/playable here).
                        if (widget.onOpenDiscover != null)
                          _discoverEntry(context.l10n, pointer: pointer, rightInset: rightInset),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (_showLoader && AppServicesScope.of(context).isSignedIn)
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _loaded,
            child: AnimatedOpacity(
              opacity: _loaded ? 0 : 1,
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeInOut,
              onEnd: () {
                if (_loaded && mounted) setState(() => _showLoader = false);
              },
              child: const CinemaLoader(),
            ),
          ),
        ),
    ]);
  }

  /// A visually distinct entry into the real discovery feed. Kept apart from
  /// library rows so "discover" titles never look like owned content.
  Widget _discoverEntry(L10n l10n, {required bool pointer, required double rightInset}) {
    return Padding(
      padding: EdgeInsets.only(left: contentLeft, right: rightInset, top: 40, bottom: pointer ? 60.0 : 200.0),
      child: TvFocusable(
        onSelect: widget.onOpenDiscover,
        builder: (context, focused) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          decoration: BoxDecoration(
            color: focused ? Zc.surface : Zc.background,
            borderRadius: BorderRadius.circular(Zs.radiusLarge),
            border: Border.all(color: focused ? Zc.request : Zc.outline, width: 2),
          ),
          child: Row(children: [
            const Icon(Icons.explore_rounded, size: 56, color: Zc.request),
            const SizedBox(width: 24),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l10n.discover, style: Zt.title),
                const SizedBox(height: 6),
                Text(l10n.discoverySubtitle, style: Zt.label.copyWith(color: Zc.textMuted)),
              ]),
            ),
            const Icon(Icons.arrow_forward_rounded, size: 40, color: Zc.textMuted),
          ]),
        ),
      ),
    );
  }

  Widget _buildRow(_Row row, {required bool first}) {
    if (row.kind == _Kind.moods) {
      if (!_allowed.contains(row)) return const SizedBox.shrink();
      return MoodShelf(
        favoriteGenres: _profile(AppServicesScope.read(context)).then((t) => [for (final g in t.genres) g.genre]),
        onFocusHero: _focusHeroInfo,
      );
    }
    return FutureBuilder<MixedItems>(
      future: _allowed.contains(row) ? _load(row) : null,
      initialData: _resolved[row],
      builder: (context, snap) {
        final (cardW, areaH) = switch (row.kind) {
          _Kind.collections => (560.0, 560 * 0.42 + 44),
          _Kind.continueWatching => (Zs.landscapeWidth, cardAreaHeight(CardStyle.landscape)),
          _Kind.libraries => (libraryCardWidth, libraryCardWidth * 9 / 16 + 44),
          _ => (cardWidth(row.style), cardAreaHeight(row.style)),
        };
        if (snap.data == null && !snap.hasError) {
          return Padding(
            padding: const EdgeInsets.only(bottom: Zs.rowGap),
            child: SkeletonRow(cardWidth: cardW, cardHeight: areaH - 100),
          );
        }
        final items = snap.data ?? const [];
        if (snap.hasError) debugPrint('[home] ${row.title(context.l10n)}: ${snap.error}');
        if (items.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: Zs.rowGap),
          child: MediaRow(
            title: row.title(context.l10n),
            trailingTitle: row.smartSpec != null && widget.onOpenSmartList != null
                ? TvFocusable(
                    onSelect: () => widget.onOpenSmartList!.call(row.smartSpec!),
                    builder: (context, focused) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      child: Text(
                        context.l10n.smartMore,
                        style: Zt.label.copyWith(
                          color: focused ? Colors.white : Zc.textMuted,
                          fontSize: 20,
                          decoration: focused ? TextDecoration.underline : null,
                        ),
                      ),
                    ),
                  )
                : null,
            height: areaH,
            gap: switch ((row.kind, row.style)) {
              (_Kind.collections, _) => 28,
              (_Kind.libraries, _) => Zs.cardGap,
              (_, CardStyle.ranked) => 8,
              (_, CardStyle.spotlight) => 30,
              _ => Zs.cardGap,
            },
            itemCount: items.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _card(row, items[i], rank: i + 1, autofocus: first && i == 0),
            ),
          ),
        );
      },
    );
  }

  Widget _card(_Row row, Object data, {required int rank, required bool autofocus}) {
    if (data is LibraryView) {
      return LibraryCard(
        view: data,
        width: libraryCardWidth,
        autofocus: autofocus,
        onFocus: () => _focusData(data),
        onSelect: () => widget.onOpenLibraryView?.call(data),
      );
    }
    if (row.kind == _Kind.collections && data is EmbyItem) {
      return CollectionCard(item: data, autofocus: autofocus, onFocus: () => _focusData(data), onSelect: () => openItem(context, data));
    }
    if (row.kind == _Kind.continueWatching && data is EmbyItem) {
      final item = data;
      final remaining = item.resumePosition == null || item.runtime == null
          ? null
          : formatRuntime(context.l10n, item.runtime! - item.resumePosition!);
      return LandscapeCard(
        item: item,
        autofocus: autofocus,
        title: item.isEpisode ? item.seriesName ?? item.name : item.name,
        subtitle: item.isEpisode
            ? [item.episodeCode, item.name].whereType<String>().join('  ')
            : remaining != null
                ? context.l10n.timeLeft(remaining)
                : item.productionYear?.toString(),
        preferEpisodeStill: false,
        onFocus: () => _focusData(item),
        onSelect: () => openItem(context, item),
        onMenu: () => _play(item),
        onPlay: () => _play(item),
      );
    }
    if (row.style == CardStyle.landscape && data is EmbyItem && data.isEpisode) {
      return LandscapeCard(
        item: data,
        autofocus: autofocus,
        title: data.seriesName ?? data.name,
        subtitle: [data.episodeCode, data.name].whereType<String>().join('  '),
        onFocus: () => _focusData(data),
        onSelect: () => openItem(context, data),
        onPlay: () => _play(data),
      );
    }
    return mixedCard(context, data, style: row.style, rank: rank, autofocus: autofocus, onFocus: () => _focusData(data));
  }
}

/// Shown until the first row resolves a usable backdrop, so the top of the
/// page never reads as an empty black rectangle while the library loads.
class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      bar(340, 46),
      const SizedBox(height: 18),
      bar(240, 16),
      const SizedBox(height: 12),
      bar(420, 14),
      const SizedBox(height: 10),
      bar(360, 14),
    ]);
  }
}
