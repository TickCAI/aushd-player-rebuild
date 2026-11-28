import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zerk_play/core/emby/models/emby_item.dart';
import 'package:zerk_play/core/emby/models/media_source.dart';
import 'package:zerk_play/data/scraper/scraper_cache.dart';
import 'package:zerk_play/data/scraper/smart_scraper.dart';
import 'package:zerk_play/data/tmdb_api.dart';

/// Builds an Emby item that looks like a library entry the upstream server
/// never scraped: no provider ids, no server artwork.
EmbyItem _unscraped({
  String id = 'item-1',
  String name = 'Untitled',
  String type = 'Movie',
  int? year,
  String? path,
  String? imdb,
}) =>
    EmbyItem(
      id: id,
      name: name,
      type: type,
      productionYear: year,
      providerIds: {if (imdb != null) 'Imdb': imdb},
      mediaSources: [
        if (path != null)
          MediaSourceInfo(id: 'src-1', streams: const [], chapters: const [], path: path),
      ],
    );

TmdbApi _api(String body, {int status = 200}) => TmdbApi(
      apiKey: 'test-key',
      client: MockClient((_) async => http.Response(body, status, headers: {'content-type': 'application/json'})),
    );

class MockClient extends http.BaseClient {
  MockClient(this._handler);
  final Future<http.Response> Function(http.BaseRequest) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

void main() {
  setUp(() async {
    await ScraperCache.instance.clear();
  });

  group('SmartScraper gating', () {
    test('is a no-op without a TMDB key', () async {
      final scraper = SmartScraper(tmdb: null);
      final item = _unscraped(name: 'Inception', path: '/m/Inception.2010.mkv');
      final result = await scraper.scrape(item);
      expect(result.applied, isFalse);
      expect(result.verdict, 'skip');
      expect(identical(result.item, item), isTrue, reason: 'must return the untouched item');
    });

    test('never rescrapes an item that already has a tmdb id', () async {
      final item = EmbyItem(
        id: 'x',
        name: 'Inception',
        type: 'Movie',
        providerIds: const {'Tmdb': '27205'},
      );
      final scraper = SmartScraper(tmdb: _api('{"results":[]}'));
      final result = await scraper.scrape(item);
      expect(result.applied, isFalse);
      expect(result.reason, 'has-provider-id');
    });
  });

  group('SmartScraper matching', () {
    test('applies a confident poster from the filename guess', () async {
      const body = '''
{"results":[
  {"id":27205,"media_type":"movie","title":"盗梦空间","original_title":"Inception",
   "release_date":"2010-07-16","poster_path":"/inception.jpg","overview":"梦境入侵"}
]}
''';
      final scraper = SmartScraper(tmdb: _api(body));
      final result = await scraper.scrape(_unscraped(name: 'Inception.2010.1080p', path: '/m/Inception.2010.1080p.mkv'));
      expect(result.applied, isTrue);
      expect(result.item.localizedPosterPath, '/inception.jpg');
      expect(result.item.overview, '梦境入侵');
      expect(scraper.appliedCount, 1);
    });

    test('skips when the best candidate is far from the filename', () async {
      const body = '''
{"results":[
  {"id":1,"media_type":"movie","title":"Interstellar","release_date":"2014-11-07","poster_path":"/i.jpg"}
]}
''';
      final scraper = SmartScraper(tmdb: _api(body));
      final result = await scraper.scrape(_unscraped(name: 'Inception', path: '/m/Inception.2010.mkv'));
      expect(result.applied, isFalse);
      expect(result.verdict, isNot('auto'));
      expect(result.item.localizedPosterPath, isNull);
    });

    test('a review-level match is cached but not applied', () async {
      const body = '''
{"results":[
  {"id":9,"media_type":"movie","title":"Dark Knight","poster_path":"/dk.jpg"}
]}
''';
      final scraper = SmartScraper(tmdb: _api(body));
      final first = await scraper.scrape(_unscraped(name: 'The Dark Knight', path: '/m/The Dark Knight.mkv'));
      expect(first.applied, isFalse);
      expect(first.verdict, 'review');
      // A second call must stay unapplied even though the decision is cached.
      final second = await scraper.scrape(_unscraped(name: 'The Dark Knight', path: '/m/The Dark Knight.mkv'));
      expect(second.applied, isFalse);
      expect(second.reason, 'cached-review');
    });

    test('an empty result set is remembered as a miss and re-used', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{"results":[]}', 200, headers: {'content-type': 'application/json'});
      });
      final scraper = SmartScraper(tmdb: TmdbApi(apiKey: 'k', client: client));
      final item = _unscraped(name: 'Nonexistent Film', path: '/m/Nonexistent Film 2021.mkv');
      await scraper.scrape(item);
      final second = await scraper.scrape(item);
      expect(calls, 1, reason: 'the cached miss must not hit the network again');
      expect(second.reason, 'cached-miss');
    });

    test('a network failure never throws and never applies artwork', () async {
      final scraper = SmartScraper(tmdb: _api('boom', status: 500));
      final result = await scraper.scrape(_unscraped(name: 'Inception', path: '/m/Inception.2010.mkv'));
      expect(result.applied, isFalse);
      expect(result.verdict, 'error');
    });
  });

  group('SmartScraper.prefetch', () {
    test('only prefetches items that are genuinely missing artwork', () async {
      final scraper = SmartScraper(tmdb: _api('{"results":[]}'));
      final withPoster = EmbyItem(
        id: 'p',
        name: 'Has Art',
        type: 'Movie',
        primaryImageTag: 'abc',
      );
      final withTmdb = EmbyItem(
        id: 't',
        name: 'Has Id',
        type: 'Movie',
        providerIds: const {'Tmdb': '1'},
      );
      await scraper.prefetch([withPoster, withTmdb]);
      expect(scraper.attemptedCount, 0, reason: 'nothing to scrape');
    });
  });

  group('clearCache', () {
    test('wipes stored decisions', () async {
      await ScraperCache.instance.store('name:foo', const {'apply': true, 'posterPath': '/p.jpg'});
      expect(ScraperCache.instance.lookup('name:foo'), isNotNull);
      await SmartScraper(tmdb: null).clearCache();
      expect(ScraperCache.instance.lookup('name:foo'), isNull);
    });
  });
}
