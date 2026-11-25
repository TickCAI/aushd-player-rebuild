import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zerk_play/data/danmaku/danmaku.dart';
import 'package:zerk_play/data/danmaku/danmaku_service.dart';
import 'package:zerk_play/playback/danmaku/danmaku_ass.dart';

void main() {
  group('DanmakuCodec.parseBilibiliXml', () {
    test('maps mode, time, color and unescapes text', () {
      const xml = '''
<d p="12.5,1,25,16711680,0,0">Hello &amp; world</d>
<d p="3.0,5,25,0,0,0">top line</d>
<d p="20.0,4,25,0,0,0">bottom line</d>
''';
      final items = DanmakuCodec.parseBilibiliXml(xml);
      expect(items, hasLength(3));
      // sorted by time: 3.0, 12.5, 20.0
      expect(items[0].timeMs, 3000);
      expect(items[0].mode, DanmakuMode.top);
      expect(items[1].text, 'Hello & world');
      expect(items[1].mode, DanmakuMode.scroll);
      expect(items[1].color, 16711680);
      expect(items[2].mode, DanmakuMode.bottom);
    });

    test('skips malformed lines without throwing', () {
      const xml = '<d p="bad">x</d><d p="5.0">short</d><d p="5.0,1,25,0,0,0"></d>';
      expect(DanmakuCodec.parseBilibiliXml(xml), isEmpty);
    });
  });

  group('DanmakuCodec.parseJson', () {
    test('parses items array with mode strings', () {
      const body = '{"items":['
          '{"timeMs":1000,"text":"a","mode":"scroll","color":16711680},'
          '{"timeMs":500,"text":"b","mode":"top"}]}';
      final items = DanmakuCodec.parseJson(body);
      expect(items, hasLength(2));
      expect(items.first.timeMs, 500); // sorted
      expect(items.first.mode, DanmakuMode.top);
      expect(items.last.color, 16711680);
    });

    test('accepts a bare array payload', () {
      final items = DanmakuCodec.parseJson('[{"timeMs":1,"text":"x"}]');
      expect(items.single.text, 'x');
    });
  });

  group('DanmakuCodec.parseAuto', () {
    test('dispatches on payload shape', () {
      expect(DanmakuCodec.parseAuto('<d p="1.0,1,25,0,0,0">t</d>').single.mode, DanmakuMode.scroll);
      expect(DanmakuCodec.parseAuto('{"items":[{"timeMs":1,"text":"t"}]}'), hasLength(1));
      expect(DanmakuCodec.parseAuto('not json'), isEmpty);
    });
  });

  group('DanmakuAss.render', () {
    test('produces a valid ASS with styles and dialogue', () {
      final ass = DanmakuAss.render([
        Danmaku(timeMs: 0, text: 'scroll', mode: DanmakuMode.scroll),
        Danmaku(timeMs: 1000, text: 'top', mode: DanmakuMode.top, color: 0xFF0000),
      ]);
      expect(ass, contains('[Script Info]'));
      expect(ass, contains('[V4+ Styles]'));
      expect(ass, contains('[Events]'));
      expect(ass, contains('Dialogue:'));
      // scroll line gets a \move override
      expect(ass, contains(r'\move('));
      // red (0xFF0000) must become BBGGRR = 0000FF
      expect(ass, contains(r'\1c&H0000FF&'));
    });

    test('stamps are HH:MM:SS.cc', () {
      final ass = DanmakuAss.render([Danmaku(timeMs: 3723450, text: 'x', mode: DanmakuMode.top)]);
      expect(ass, contains('01:02:03.45'));
    });

    test('escapes braces and backslashes', () {
      final ass = DanmakuAss.render([Danmaku(timeMs: 0, text: r'{a\b}', mode: DanmakuMode.top)]);
      expect(ass, contains(r'\{a\\b\}'));
    });

    test('empty list still renders a valid header-only document', () {
      final ass = DanmakuAss.render([]);
      expect(ass, contains('[Events]'));
      expect(ass, isNot(contains('Dialogue:')));
    });
  });

  group('DanmakuService', () {
    test('load returns empty when disabled', () async {
      final svc = DanmakuService();
      svc.applyConfigSources([
        {'id': 'a', 'name': 'A', 'url': 'http://x/{tmdb}'},
      ]);
      expect(svc.enabled, isFalse);
      final out = await svc.load(const DanmakuMedia(tmdbId: 1));
      expect(out, isEmpty);
    });

    test('load fetches via provider when enabled and caches', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('{"items":[{"timeMs":1,"text":"t"}]}', 200);
      });
      final svc = DanmakuService();
      svc.applyConfigSources([
        {'id': 'a', 'name': 'A', 'url': 'http://x/{tmdb}'},
      ], client: client);
      svc.setEnabled(true);
      expect(svc.enabled, isTrue);
      final media = const DanmakuMedia(tmdbId: 42);
      final first = await svc.load(media);
      expect(first, hasLength(1));
      final second = await svc.load(media);
      expect(second, hasLength(1));
      expect(calls, 1, reason: 'second call must hit the cache');
    });

    test('provider failure yields empty, not a throw', () async {
      final client = MockClient((_) async => throw http.ClientException('down'));
      final svc = DanmakuService();
      svc.applyConfigSources([
        {'id': 'a', 'name': 'A', 'url': 'http://x/{tmdb}'},
      ], client: client);
      svc.setEnabled(true);
      expect(await svc.load(const DanmakuMedia(tmdbId: 1)), isEmpty);
    });

    test('no sources means inert even if enabled requested', () async {
      final svc = DanmakuService();
      svc.setEnabled(true);
      expect(svc.enabled, isFalse);
      expect(svc.hasProviders, isFalse);
    });

    test('user-added source enables the service on its own', () async {
      final svc = DanmakuService();
      expect(svc.hasProviders, isFalse);
      final id = svc.addUserSource(name: 'My API', url: 'http://x/{tmdb}/{episode}');
      expect(svc.hasProviders, isTrue);
      expect(svc.enabled, isTrue, reason: 'adding a source turns danmaku on');
      expect(svc.isUserSource(id), isTrue);
      expect(svc.providerId, id);
      expect(svc.providers.first.displayName, 'My API');
    });

    test('removeUserSource drops the last source and disables', () {
      final svc = DanmakuService();
      final id = svc.addUserSource(name: 'A', url: 'http://x/{tmdb}');
      expect(svc.hasProviders, isTrue);
      svc.removeUserSource(id);
      expect(svc.hasProviders, isFalse);
      expect(svc.enabled, isFalse);
      expect(svc.isUserSource(id), isFalse);
    });

    test('config sources and user sources coexist', () {
      final svc = DanmakuService();
      svc.applyConfigSources([
        {'id': 'cfg', 'name': 'Config', 'url': 'http://c/{tmdb}'},
      ]);
      final uid = svc.addUserSource(name: 'User', url: 'http://u/{tmdb}');
      expect(svc.providers, hasLength(2));
      expect(svc.isUserSource('cfg'), isFalse);
      expect(svc.isUserSource(uid), isTrue);
      // A later config refresh must not erase the user's own source.
      svc.applyConfigSources([
        {'id': 'cfg2', 'name': 'Config2', 'url': 'http://c2/{tmdb}'},
      ]);
      expect(svc.providers, hasLength(2));
      expect(svc.isUserSource(uid), isTrue);
    });
  });
}
