import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/core/emby/models/emby_item.dart';
import 'package:zerk_play/data/smart_list.dart';
import 'package:zerk_play/data/taste_profile.dart';

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

void main() {
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
      // Only the genre dimension is available -> one of one.
      expect(
        tasteMatch(item, const TasteProfile(genres: [(genre: 'Drama', count: 1)])),
        1,
      );
    });

    test('itemScore is the documented weighted sum', () {
      final now = DateTime.utc(2026, 1, 1);
      final item = _item('s', rating: 8, date: now);
      final expected = 0.45 * 0.8 + 0.30 * 0 + 0.15 * 1 + 0.10 * stableJitter('s');
      expect(itemScore(item, const TasteProfile(), now: now), closeTo(expected, 1e-9));
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
      final gems = SmartSpec.gems; // maxRating 7.8, IsUnplayed
      expect(matchesLocal(_item('ok', rating: 7), gems, now: now), isTrue);
      expect(matchesLocal(_item('hi', rating: 8.5), gems, now: now), isFalse);
      expect(matchesLocal(_item('played', rating: 7, played: true), gems, now: now), isFalse);
      final classics = SmartSpec.classics; // maxYear 2015
      expect(matchesLocal(_item('new', year: 2024), classics, now: now), isFalse);
      expect(matchesLocal(_item('old', year: 2010), classics, now: now), isTrue);
    });

    test('time window uses the configured date field', () {
      final now = DateTime.utc(2026, 1, 1);
      final week = SmartSpec.thisWeek; // windowDays 7, DateCreated
      expect(matchesLocal(_item('fresh', created: now.subtract(const Duration(days: 3))), week, now: now), isTrue);
      expect(matchesLocal(_item('stale', created: now.subtract(const Duration(days: 30))), week, now: now), isFalse);
    });

    test('a shelf hides itself below minItems', () {
      final spec = SmartSpec.classics; // minItems 6
      expect(spec.hides(List.filled(5, _item('x'))), isTrue);
      expect(spec.hides(List.filled(6, _item('x'))), isFalse);
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
