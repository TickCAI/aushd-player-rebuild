import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/data/scraper/filename_guess.dart';
import 'package:zerk_play/data/scraper/match_score.dart';
import 'package:zerk_play/data/scraper/scraper_cache.dart';

void main() {
  group('FilenameGuesser', () {
    const guesser = FilenameGuesser();

    test('parses movie title, year and quality tags', () {
      final g = guesser.guess('Inception.2010.1080p.BluRay.x264.mkv')!;
      expect(g.title, 'Inception');
      expect(g.year, 2010);
      expect(g.isTv, isFalse);
      expect(g.confidence, greaterThan(0.6));
    });

    test('parses SxxEyy for TV and keeps the series name', () {
      final g = guesser.guess('Breaking.Bad.S01E05.720p.WEB-DL.mkv')!;
      expect(g.title, 'Breaking Bad');
      expect(g.season, 1);
      expect(g.episode, 5);
      expect(g.isTv, isTrue);
      expect(g.hasEpisode, isTrue);
    });

    test('parses 第N季第N集 Chinese naming', () {
      final g = guesser.guess('庆余年 第1季第3集 1080p.mkv')!;
      expect(g.title, '庆余年');
      expect(g.season, 1);
      expect(g.episode, 3);
      expect(g.isTv, isTrue);
    });

    test('rejects pure numbers and empty names', () {
      expect(guesser.guess('1080p.mkv'), isNull);
      expect(guesser.guess('   '), isNull);
    });
  });

  group('MatchScorer', () {
    const scorer = MatchScorer();

    test('exact title and year is auto-accepted', () {
      final s = scorer.score(
        queryTitle: 'Inception',
        candidateTitle: 'Inception',
        queryYear: 2010,
        candidateYear: 2010,
      );
      expect(s.score, greaterThanOrEqualTo(MatchScorer.autoThreshold));
      expect(scorer.verdict(s).label, 'auto');
    });

    test('wrong year and different title is skipped', () {
      final s = scorer.score(
        queryTitle: 'Inception',
        candidateTitle: 'Interstellar',
        queryYear: 2010,
        candidateYear: 2014,
      );
      expect(scorer.verdict(s).label, 'skip');
    });

    test('a clear winner over a weak runner-up is auto', () {
      final a = scorer.score(queryTitle: 'The Dark Knight', candidateTitle: 'The Dark Knight');
      final b = scorer.score(queryTitle: 'The Dark Knight', candidateTitle: 'Batman Begins');
      expect(scorer.verdict(a, secondBest: b.score).label, 'auto');
    });

    test('mid-range scores with a close contender require review', () {
      final partial = scorer.score(queryTitle: 'The Dark Knight', candidateTitle: 'Dark Knight');
      expect(partial.score, greaterThanOrEqualTo(MatchScorer.reviewThreshold));
      expect(partial.score, lessThan(MatchScorer.autoThreshold));
      expect(scorer.verdict(partial, secondBest: partial.score - 0.01).label, 'review');
      expect(scorer.verdict(partial, secondBest: partial.score - 0.2).label, 'auto');
    });
  });

  group('scraperCacheKey', () {
    test('prefers tmdb id then imdb id', () {
      expect(scraperCacheKey(tmdbId: '123', imdbId: 'tt456', name: 'X'), 'tmdb:123');
      expect(scraperCacheKey(imdbId: 'tt456', name: 'X'), 'imdb:tt456');
    });

    test('uses normalized name+year without upstream id', () {
      expect(scraperCacheKey(name: 'The  Matrix!', year: 1999), 'name:the matrix:1999');
    });

    test('falls back to path hash and never uses an item id', () {
      final a = scraperCacheKey(name: '', path: '/media/a.mkv');
      final b = scraperCacheKey(name: '', path: '/media/a.mkv');
      expect(a, b);
      expect(a.startsWith('path:'), isTrue);
      expect(a.contains('/media'), isFalse);
    });
  });
}
