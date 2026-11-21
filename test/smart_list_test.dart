import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/core/emby/models/emby_item.dart';
import 'package:zerk_play/core/storage/local_store.dart';
import 'package:zerk_play/data/catalog_api.dart';
import 'package:zerk_play/data/smart_list.dart';
import 'package:zerk_play/data/taste_profile.dart';
import 'package:zerk_play/services/janus/janus_service.dart';

EmbyItem _item(
  String id, {
  double? rating,
  int? year,
  DateTime? date,
  DateTime? created,
  bool played = false,
  List<String> genres = const [],
}) =>
    EmbyItem(
      id: id,
      name: id,
      type: 'Movie',
      communityRating: rating,
      productionYear: year,
      premiereDate: date,
      dateCreated: created,
      isPlayed: played,
      genres: genres,
    );

/// resolveMixed's local branch for the `my-list` spec is kind=local and never
/// touches the catalog, so a store that would otherwise fail on a real query is
/// enough to construct the resolver.
class _FakeStore implements LocalStore {
  final Map<String, String> _values = {};

  @override
  Future<void> init() async {}

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String value) async => _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);
}

SmartListResolver _resolver({SmartTopUp? topUp}) => SmartListResolver(
      CatalogApi(
        janus: JanusService(store: _FakeStore(), deviceName: 'test', appVersion: 'test'),
      ),
      const TasteProfile(),
      topUp: topUp,
    );

void main() {
  setUp(() => SmartListResolver.invalidate());

  group('scoring primitives', () {
    test('rating is normalized and clamped', () {
      expect(normRating(null), 0);
      expect(normRating(8), closeTo(0.8, 1e-9));
      expect(normRating(10), 1);
      expect(normRating(30), 1);
      expect(normRating(-5), 0);
    });

    test('jitter is deterministic and folded into [0,1)', () {
      expect(stableJitter('abc'), stableJitter('abc'));
      for (final id in ['a', 'b', 'x-long-id', '中文']) {
        final j = stableJitter(id);
        expect(j, greaterThanOrEqualTo(0));
        expect(j, lessThan(1));
      }
    });

    test('freshness decays with a three-year half-life', () {
      final now = DateTime.utc(2026, 1, 1);
      expect(freshness(_item('x', date: now), now: now), 1);
      final threeYears = freshness(_item('x', date: DateTime.utc(2023, 1, 1)), now: now);
      expect(threeYears, closeTo(0.5, 0.02));
      expect(freshness(_item('x'), now: now), closeTo(0.3, 1e-9));
    });

    test('tasteMatch weights genre, actor and director dimensions', () {
      final actor = Person(id: 'a1', name: 'Actor', type: 'Actor');
      final director = Person(id: 'd1', name: 'Director', type: 'Director');
      final item = EmbyItem(
        id: 'i',
        name: 'i',
        type: 'Movie',
        genres: const ['Drama'],
        people: [actor, director],
      );
      final taste = TasteProfile(
        genres: const [(genre: 'Drama', count: 3)],
        actors: [(person: actor, count: 2)],
        directors: [(person: director, count: 1)],
      );
      expect(tasteMatch(item, taste), 1);
      expect(tasteMatch(item, const TasteProfile()), 0);
      expect(
        tasteMatch(item, const TasteProfile(genres: [(genre: 'Drama', count: 1)])),
        1,
      );
    });

    test('itemScore defaults to the documented weighted sum', () {
      final now = DateTime.utc(2026, 1, 1);
      final item = _item('s', rating: 8, date: now);
      final expected = 0.45 * 0.8 + 0.30 * 0 + 0.15 * 1 + 0.10 * stableJitter('s');
      expect(itemScore(item, const TasteProfile(), now: now), closeTo(expected, 1e-9));
    });

    test('each shelf uses its own scoring weights', () {
      final now = DateTime.utc(2026, 1, 1);
      final oldHit = _item('old', rating: 9, date: DateTime.utc(2000, 1, 1));
      final newHit = _item('new', rating: 9, date: now);

      // classics ignores freshness: age must not cost it points.
      expect(itemScore(oldHit, const TasteProfile(), now: now, spec: SmartSpec.classics),
          closeTo(itemScore(newHit, const TasteProfile(), now: now, spec: SmartSpec.classics), 1e-9));
      // fresh rewards recency heavily.
      expect(itemScore(newHit, const TasteProfile(), now: now, spec: SmartSpec.fresh),
          greaterThan(itemScore(oldHit, const TasteProfile(), now: now, spec: SmartSpec.fresh)));

      expect(SmartSpec.classics.wFresh, 0);
      expect(SmartSpec.gems.wJitter, closeTo(0.30, 1e-9));
      expect(SmartSpec.picks.wTaste, closeTo(0.50, 1e-9));
    });
  });

  group('shelf rules', () {
    test('dedupe keeps the first occurrence', () {
      final out = dedupeById([_item('a'), _item('a'), _item('b'), _item('b'), _item('c')]);
      expect(out.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('scoreSort orders by descending score, stable by id on ties', () {
      final now = DateTime.utc(2026, 1, 1);
      final items = [
        _item('low', rating: 3, date: now),
        _item('high', rating: 9, date: now),
        _item('mid', rating: 6, date: now),
      ];
      final out = scoreSort(items, const TasteProfile(), now: now);
      expect(out.map((e) => e.id), ['high', 'mid', 'low']);
    });

    test('matchesLocal enforces upper rating, year ceiling and unplayed', () {
      final now = DateTime.utc(2026, 1, 1);
      final gems = SmartSpec.gems;
      expect(matchesLocal(_item('ok', rating: 7), gems, now: now), isTrue);
      expect(matchesLocal(_item('hi', rating: 8.5), gems, now: now), isFalse);
      expect(matchesLocal(_item('played', rating: 7, played: true), gems, now: now), isFalse);
      final classics = SmartSpec.classics;
      expect(classics.maxYear, isNull); // old classics must not be punished
      expect(matchesLocal(_item('old', year: 2010), classics, now: now), isTrue);
    });

    test('time window uses the configured date field', () {
      final now = DateTime.utc(2026, 1, 1);
      final week = SmartSpec.thisWeek;
      expect(matchesLocal(_item('fresh', created: now.subtract(const Duration(days: 3))), week, now: now), isTrue);
      expect(matchesLocal(_item('stale', created: now.subtract(const Duration(days: 30))), week, now: now), isFalse);
    });

    test('a shelf hides itself below minItems', () {
      final spec = SmartSpec.classics;
      expect(spec.hides(List.filled(5, _item('x'))), isTrue);
      expect(spec.hides(List.filled(6, _item('x'))), isFalse);
    });
  });

  group('mixed shelf', () {
    test('top-up fills a local-only shelf and dedupes by id', () async {
      final resolver = _resolver(topUp: (spec, missing) async => [
            _item('a'),
            _item('a'), // duplicate must be dropped
            _item('b'),
          ]);
      final out = await resolver.resolveMixed(SmartSpec.myList);
      expect(out.whereType<EmbyItem>().map((e) => e.id), ['a', 'b']);
    });

    test('a failing top-up degrades to the local shelf, never throws', () async {
      final resolver = _resolver(topUp: (spec, missing) async => throw StateError('offline'));
      final out = await resolver.resolveMixed(SmartSpec.myList);
      expect(out, isEmpty); // local shelf empty + minItems 1 -> hidden
    });

    test('top-up result is cached and reuse avoids a second call', () async {
      var calls = 0;
      final resolver = _resolver(topUp: (spec, missing) async {
        calls++;
        return [_item('a')];
      });
      await resolver.resolveMixed(SmartSpec.myList);
      await resolver.resolveMixed(SmartSpec.myList);
      expect(calls, 1);
    });
  });

  group('spec catalogue', () {
    test('home exposes six uniquely identified shelves', () {
      expect(SmartSpec.home.length, 6);
      expect(SmartSpec.home.map((s) => s.id).toSet().length, 6);
      for (final s in SmartSpec.home) {
        expect(SmartSpec.byId(s.id), same(s));
      }
      expect(SmartSpec.byId('my-list'), SmartSpec.myList);
      expect(SmartSpec.byId('nope'), isNull);
    });

    test('every home shelf declares an achievable limit', () {
      for (final s in SmartSpec.home) {
        expect(s.limit, greaterThanOrEqualTo(s.minItems));
        expect(s.minItems, greaterThan(0));
      }
    });
  });
}
