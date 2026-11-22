import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/data/discovery_feed.dart';
import 'package:zerk_play/data/seerr_api.dart';

SeerrMedia _m(int id, {SeerrMediaType type = SeerrMediaType.movie}) => SeerrMedia(
      tmdbId: id,
      type: type,
      title: 'Title $id',
      posterPath: '/p$id.jpg',
    );

void main() {
  group('discovery categories', () {
    test('all seven categories are distinct with stable ids / l10n keys', () {
      final ids = <String>{};
      final keys = <String>{};
      for (final c in DiscoveryCategory.values) {
        expect(ids.add(c.id), isTrue, reason: 'duplicate id ${c.id}');
        expect(keys.add(c.l10nKey), isTrue, reason: 'duplicate l10n key ${c.l10nKey}');
      }
      expect(DiscoveryCategory.values.length, 7);
    });
  });

  group('DiscoveryFilters', () {
    test('default filters are inactive and have a stable signature', () {
      const f = DiscoveryFilters();
      expect(f.isActive, isFalse);
      expect(f.signature, 'all|hot|null|null|null');
    });

    test('every filter dimension flips isActive and changes the signature', () {
      const base = DiscoveryFilters();
      const media = DiscoveryFilters(mediaType: FilterMediaType.tv);
      const sort = DiscoveryFilters(sort: FilterSort.rating);
      const year = DiscoveryFilters(yearFrom: 2020, yearTo: 2024);
      const genre = DiscoveryFilters(genre: 878);

      for (final f in [media, sort, year, genre]) {
        expect(f.isActive, isTrue);
        expect(f.signature, isNot(base.signature));
      }
      expect(media.signature, 'tv|hot|null|null|null');
      expect(sort.signature, 'all|rating|null|null|null');
      expect(year.signature, 'all|hot|2020|2024|null');
      expect(genre.signature, 'all|hot|null|null|878');
    });

    test('genre 0 counts as inactive (the "All" option)', () {
      expect(const DiscoveryFilters(genre: 0).isActive, isFalse);
    });

    test('genre and year option tables have unique ids', () {
      final genres = DiscoveryFilters.genreOptions.map((o) => o.$1).toSet();
      expect(genres.length, DiscoveryFilters.genreOptions.length);
      final years = DiscoveryFilters.yearOptions
          .map((o) => '${o.$1}/${o.$2}')
          .toSet();
      expect(years.length, DiscoveryFilters.yearOptions.length);
    });
  });

  group('DiscoveryFeed pagination', () {
    test('appends pages in order and de-duplicates by key', () async {
      final seenPages = <int>[];
      final feed = DiscoveryFeed(DiscoveryCategory.trending, (category, {required int page}) async {
        seenPages.add(page);
        if (page == 1) return [_m(1), _m(2), _m(3)];
        if (page == 2) return [_m(3), _m(4), _m(5)]; // id 3 repeats
        return [];
      });

      expect(await feed.loadMore(), 3);
      expect(await feed.loadMore(), 2);
      expect(feed.items.map((m) => m.tmdbId).toList(), [1, 2, 3, 4, 5]);
      expect(seenPages, [1, 2]);
      expect(feed.loadedPage, 2);
    });

    test('keeps movie and tv with same tmdb id as distinct titles', () async {
      final feed = DiscoveryFeed(DiscoveryCategory.todayPicks, (_, {required int page}) async =>
          page == 1 ? [_m(10), _m(10, type: SeerrMediaType.tv)] : []);
      expect(await feed.loadMore(), 2);
      expect(feed.items.length, 2);
    });

    test('stops paging when a page adds nothing new', () async {
      var calls = 0;
      final feed = DiscoveryFeed(DiscoveryCategory.nowPlaying, (_, {required int page}) async {
        calls++;
        return [_m(1)];
      });
      expect(await feed.loadMore(), 1);
      expect(await feed.loadMore(), 0); // page 2 adds nothing new
      expect(feed.hasMore, isFalse);
      expect(await feed.loadMore(), 0);
      expect(calls, 2, reason: 'no fetch after hasMore is false');
    });

    test('a fetch error ends the session without throwing', () async {
      final feed = DiscoveryFeed(DiscoveryCategory.animation, (_, {required int page}) async {
        throw StateError('upstream down');
      });
      expect(await feed.loadMore(), 0);
      expect(feed.hasMore, isFalse);
    });

    test('ignores concurrent loadMore calls', () async {
      final completer = Completer<List<SeerrMedia>>();
      var calls = 0;
      final feed = DiscoveryFeed(DiscoveryCategory.trending, (_, {required int page}) async {
        calls++;
        return completer.future;
      });
      final a = feed.loadMore();
      final b = feed.loadMore(); // should be ignored while loading
      expect(feed.isLoading, isTrue);
      completer.complete([_m(1)]);
      await Future.wait([a, b]);
      expect(calls, 1);
      expect(feed.items.length, 1);
    });

    test('reset restores a fresh pagination state', () async {
      final feed = DiscoveryFeed(DiscoveryCategory.topRated, (_, {required int page}) async => [_m(page)]);
      await feed.loadMore();
      await feed.loadMore();
      expect(feed.items.length, 2);
      feed.reset();
      expect(feed.items, isEmpty);
      expect(feed.loadedPage, 0);
      expect(feed.hasMore, isTrue);
      expect(await feed.loadMore(), 1);
    });
  });
}
