import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zerk_play/core/storage/local_store.dart';
import 'package:zerk_play/data/mount/ftp_vfs.dart';
import 'package:zerk_play/data/mount/mount_service.dart';
import 'package:zerk_play/data/mount/openlist_vfs.dart';
import 'package:zerk_play/data/mount/virtual_file_system.dart';
import 'package:zerk_play/data/mount/webdav_vfs.dart';

void main() {
  group('VfsPath', () {
    test('normalize collapses slashes, dots and backslashes', () {
      expect(VfsPath.normalize(''), '/');
      expect(VfsPath.normalize('/'), '/');
      expect(VfsPath.normalize('a/b'), '/a/b');
      expect(VfsPath.normalize('//a///b/'), '/a/b');
      expect(VfsPath.normalize(r'\a\b\c'), '/a/b/c');
      expect(VfsPath.normalize('/a/./b'), '/a/b');
      expect(VfsPath.normalize('/a/b/../c'), '/a/c');
      expect(VfsPath.normalize('/../../x'), '/x'); // never escapes root
    });

    test('join / basename / dirname', () {
      expect(VfsPath.join('/', 'a'), '/a');
      expect(VfsPath.join('/a', 'b/c'), '/a/b/c');
      expect(VfsPath.join('/a/', '/b'), '/a/b');
      expect(VfsPath.basename('/a/b.mkv'), 'b.mkv');
      expect(VfsPath.basename('/'), '/');
      expect(VfsPath.dirname('/a/b'), '/a');
      expect(VfsPath.dirname('/a'), '/');
    });

    test('encode keeps separators but escapes segments', () {
      expect(VfsPath.encode('/电影/第 1 集.mp4'), '/%E7%94%B5%E5%BD%B1/%E7%AC%AC%201%20%E9%9B%86.mp4');
      expect(VfsPath.encode('/'), '/');
    });
  });

  group('OpenListVfs', () {
    test('directUrl builds /d/<encoded path> under the base', () {
      final vfs = OpenListVfs(baseUrl: 'https://list.example.com/');
      expect(vfs.directUrl('/电影/a b.mkv').toString(),
          'https://list.example.com/d/%E7%94%B5%E5%BD%B1/a%20b.mkv');
    });

    test('list parses content, sorts dirs first, normalizes child paths', () async {
      late http.Request captured;
      final vfs = OpenListVfs(
        baseUrl: 'https://list.example',
        token: 'tk',
        client: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'content': [
                  {'name': 'b.mkv', 'is_dir': false, 'size': 123, 'path': '/tv/b.mkv'},
                  {'name': 'a', 'is_dir': true},
                  {'name': 'c', 'is_dir': false, 'size': 5},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final files = await vfs.list('/tv');
      expect(captured.headers['Authorization'], 'Bearer tk');
      expect(captured.url.toString(), 'https://list.example/api/fs/list');
      expect(jsonDecode(captured.body)['path'], '/tv');
      expect(files.map((f) => f.name).toList(), ['a', 'b.mkv', 'c']); // dir first
      expect(files[0].isDir, isTrue);
      expect(files[1].path, '/tv/b.mkv'); // explicit path wins
      expect(files[2].path, '/tv/c'); // else joined with parent
      expect(files[1].size, 123);
    });

    test('list throws on non-200 code', () async {
      final vfs = OpenListVfs(
        baseUrl: 'https://list.example',
        client: MockClient((_) async => http.Response(jsonEncode({'code': 401, 'message': 'token invalid'}), 200)),
      );
      expect(() => vfs.list('/'), throwsA(isA<StateError>()));
    });
  });

  group('WebDavVfs', () {
    const multistatus = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/Movies</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/a%20b.mkv</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>42</d:getcontentlength></d:prop></d:propstat></d:response>
</d:multistatus>''';

    test('list parses PROPFIND, skips self, decodes hrefs', () async {
      late http.Request captured;
      final vfs = WebDavVfs(
        baseUrl: 'https://host/dav',
        username: 'u',
        password: 'p',
        client: MockClient((req) async {
          captured = req;
          return http.Response(multistatus, 207);
        }),
      );
      final files = await vfs.list('/');
      expect(captured.method, 'PROPFIND');
      expect(captured.headers['Depth'], '1');
      expect(captured.headers['Authorization'], startsWith('Basic '));
      expect(files.map((f) => f.name).toList(), ['Movies', 'a b.mkv']);
      expect(files[0].isDir, isTrue);
      expect(files[1].path, '/dav/a b.mkv');
      expect(files[1].size, 42);
    });

    test('resolvePlayableUrl embeds credentials for the native player', () async {
      final vfs = WebDavVfs(baseUrl: 'https://host/dav', username: 'u', password: 'p');
      final url = Uri.parse(await vfs.resolvePlayableUrl('/a b.mkv'));
      expect(url.userInfo, 'u:p');
      expect(url.path, '/dav/a%20b.mkv');
    });

    test('resolvePlayableUrl is plain when anonymous', () async {
      final vfs = WebDavVfs(baseUrl: 'https://host/dav');
      final url = await vfs.resolvePlayableUrl('/x.mp4');
      expect(url, 'https://host/dav/x.mp4');
    });
  });

  group('MountService', () {
    test('add / persist / reload / remove round-trips through the store', () async {
      final store = _MemoryStore();
      final svc = MountService(store);
      await svc.load();
      expect(svc.mounts, isEmpty);

      final m = MountDefinition(
        id: 'm1', kind: MountKind.openlist, name: 'NAS', baseUrl: 'https://list.example', token: 'tk',
      );
      await svc.add(m);
      expect(svc.mounts, hasLength(1));

      // A fresh service reads the same persisted list.
      final svc2 = MountService(store);
      await svc2.load();
      expect(svc2.mounts.single.id, 'm1');
      expect(svc2.mounts.single.kind, MountKind.openlist);
      expect(svc2.mounts.single.token, 'tk');

      // Same id replaces instead of duplicating.
      await svc2.add(MountDefinition(
        id: 'm1', kind: MountKind.webdav, name: 'DAV', baseUrl: 'https://host/dav',
      ));
      expect(svc2.mounts, hasLength(1));
      expect(svc2.mounts.single.kind, MountKind.webdav);

      await svc2.remove('m1');
      expect(svc2.mounts, isEmpty);
      expect(svc2.byId('m1'), isNull);
      expect(svc2.vfsFor('m1'), isNull);
    });

    test('vfsFor builds the right backend type', () async {
      final store = _MemoryStore();
      final svc = MountService(store);
      await svc.add(MountDefinition(id: 'o', kind: MountKind.openlist, name: 'O', baseUrl: 'https://a'));
      await svc.add(MountDefinition(id: 'w', kind: MountKind.webdav, name: 'W', baseUrl: 'https://b'));
      await svc.add(MountDefinition(id: 'f', kind: MountKind.ftp, name: 'F', baseUrl: 'ftp://host:21/x'));
      expect(svc.vfsFor('o'), isA<OpenListVfs>());
      expect(svc.vfsFor('w'), isA<WebDavVfs>());
      expect(svc.vfsFor('f'), isA<FtpVfs>());
    });

    test('protocol dropdown lists cloud brands as openlist presets', () {
      final brands = ProtocolPreset.all.where((p) => p.label != 'OpenList / AList').toList();
      expect(brands, isNotEmpty);
      for (final p in brands) {
        expect(p.kind, MountKind.openlist,
            reason: '${p.label} must bridge through OpenList');
      }
      expect(ProtocolPreset.all.any((p) => p.kind == MountKind.ftp), isTrue);
      expect(ProtocolPreset.all.any((p) => p.kind == MountKind.webdav), isTrue);
    });
  });

  group('OpenListVfs.authenticate', () {
    test('extracts the bearer token from a login response', () async {
      final client = MockClient((req) async {
        expect(req.url.path, '/api/auth/login');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['username'], 'alice');
        expect(body['password'], 'secret');
        return http.Response(
            jsonEncode({'code': 200, 'data': {'token': 'tok-123'}}), 200);
      });
      final token = await OpenListVfs.authenticate('https://list.example.com', 'alice', 'secret',
          client: client);
      expect(token, 'tok-123');
    });

    test('returns empty (no throw) on rejection or bad response', () async {
      final client = MockClient((_) async => http.Response('{"code":401}', 200));
      expect(await OpenListVfs.authenticate('https://x', 'u', 'p', client: client), '');
      expect(await OpenListVfs.authenticate('https://x', '', '', client: client), '');
    });
  });

  group('FtpVfs', () {
    test('builds a playable ftp URL with embedded credentials', () async {
      final vfs = FtpVfs(baseUrl: 'ftp://host:2121/media', username: 'u', password: 'p@ss');
      final url = await vfs.resolvePlayableUrl('/Movies/a.mkv');
      expect(url, startsWith('ftp://'));
      expect(Uri.parse(url).path, '/media/Movies/a.mkv');
      expect(Uri.parse(url).userInfo, isNotEmpty);
    });
  });
}

final class _MemoryStore implements LocalStore {
  final Map<String, String> _data = {};

  @override
  Future<void> init() async {}

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> setString(String key, String value) async => _data[key] = value;

  @override
  Future<void> remove(String key) async => _data.remove(key);
}
