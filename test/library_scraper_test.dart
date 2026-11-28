import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zerk_play/core/emby/models/emby_item.dart';
import 'package:zerk_play/core/storage/local_store.dart';
import 'package:zerk_play/data/catalog_api.dart';
import 'package:zerk_play/data/scraper/library_scraper.dart';
import 'package:zerk_play/data/scraper/smart_scraper.dart';
import 'package:zerk_play/data/tmdb_api.dart';
import 'package:zerk_play/services/janus/janus_service.dart';

/// The whole-library scan runs on an explicit button press, so these tests pin
/// down the state machine rather than the scraping itself: the fraction must
/// stay in range, a scan must never re-enter, and without a TMDB key the button
/// must do nothing at all (and in particular must not query the catalog).
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

CatalogApi _catalog() =>
    CatalogApi(janus: JanusService(store: _FakeStore(), deviceName: 'test', appVersion: 'test'));

/// Any HTTP call means a path that should have short-circuited did not.
TmdbApi _forbiddenApi() => TmdbApi(
      apiKey: 'test-key',
      client: _ForbiddenClient(),
    );

class _ForbiddenClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw StateError('unexpected network call to ${request.url}');
}

void main() {
  group('LibraryScrapeProgress', () {
    test('fraction is zero before any item is known', () {
      expect(LibraryScrapeProgress.idle.fraction, 0);
      expect(const LibraryScrapeProgress(total: 0, done: 0).fraction, 0);
    });

    test('fraction tracks done over total', () {
      expect(const LibraryScrapeProgress(total: 10, done: 5).fraction, 0.5);
      expect(const LibraryScrapeProgress(total: 10, done: 10).fraction, 1);
    });

    test('fraction clamps when done overshoots total', () {
      expect(const LibraryScrapeProgress(total: 4, done: 9).fraction, 1);
    });

    test('copyWith keeps untouched fields', () {
      const start = LibraryScrapeProgress(total: 7, done: 2, applied: 1, running: true);
      final next = start.copyWith(done: 3);
      expect(next.total, 7);
      expect(next.done, 3);
      expect(next.applied, 1);
      expect(next.running, isTrue);
      expect(next.finished, isFalse);
    });
  });

  group('LibraryScraper gating', () {
    test('without a TMDB key it does nothing and never touches the catalog', () async {
      final scraper = LibraryScraper(catalog: _catalog(), scraper: SmartScraper(tmdb: null));

      final result = await scraper.run();

      expect(result.running, isFalse);
      expect(result.finished, isFalse);
      expect(scraper.running, isFalse);
      expect(scraper.progress.value.running, isFalse);
      expect(scraper.progress.value.done, 0);

      scraper.dispose();
    });

    test('with no scraper at all it is a no-op', () async {
      final scraper = LibraryScraper(catalog: _catalog(), scraper: null);

      final result = await scraper.run();

      expect(result.running, isFalse);
      expect(result.finished, isFalse);
      expect(scraper.running, isFalse);

      scraper.dispose();
    });

    test('a second run while one is in flight returns immediately', () async {
      final scraper = LibraryScraper(
        catalog: _catalog(),
        // Available, but the re-entrancy guard is checked before any work.
        scraper: SmartScraper(tmdb: _forbiddenApi()),
      );
      scraper.progress.value = const LibraryScrapeProgress(running: true, total: 3, done: 1);

      final result = await scraper.run();

      expect(result.done, 1, reason: 'an in-flight scan must not be restarted');
      expect(result.total, 3);
      expect(scraper.progress.value.running, isTrue);

      scraper.dispose();
    });
  });

  group('needsScrape', () {
    test('false for an item that already has a server poster', () {
      final item = EmbyItem.fromJson(const {
        'Id': '1',
        'Name': 'Dune',
        'Type': 'Movie',
        'ImageTags': {'Primary': 'tag-1'},
      });
      expect(SmartScraper(tmdb: null).needsScrape(item), isFalse);
    });

    test('false once a local poster was applied', () {
      final item = EmbyItem.fromJson(const {
        'Id': '2',
        'Name': 'Dune.2021.1080p',
        'Type': 'Movie',
      }).copyWith(localizedPosterPath: '/abc.jpg');
      expect(SmartScraper(tmdb: null).needsScrape(item), isFalse);
    });

    test('true for a bare file-backed item', () {
      final item = EmbyItem.fromJson(const {
        'Id': '3',
        'Name': 'Dune.2021.1080p',
        'Type': 'Movie',
      });
      expect(SmartScraper(tmdb: null).needsScrape(item), isTrue);
    });
  });
}
