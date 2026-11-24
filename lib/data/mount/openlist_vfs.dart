import 'dart:convert';

import 'package:http/http.dart' as http;

import 'virtual_file_system.dart';

/// OpenList (an AList-compatible file-list program) storage backend.
///
/// OpenList unifies WebDAV / SMB / every cloud drive behind one HTTP gateway:
/// - directory listing: `POST /api/fs/list` with `{path, password}`
/// - direct stream:     `GET  /d/<path>` — fed straight to mpv/media3
///
/// The token is optional: public instances work without one. When present it
/// is sent as `Authorization: Bearer <token>` on every request; the mpv direct
/// URL carries it as a `sign`/query-free header is impossible for mpv, so for
/// protected files we append `?sign=` only if the listing supplied one. In
/// practice OpenList instances used for media are configured public-read.
final class OpenListVfs implements VirtualFileSystem {
  OpenListVfs({
    required String baseUrl,
    this.token = '',
    this.password = '',
    http.Client? client,
    String? id,
  })  : base = _base(baseUrl),
        _client = client ?? http.Client(),
        id = id ?? 'openlist:${_base(baseUrl)}';

  static String _base(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  @override
  final String id;

  final String base;
  final String token;
  final String password;
  final http.Client _client;

  @override
  String get displayName => 'OpenList';

  Map<String, String> get _headers => token.isEmpty ? const {} : {'Authorization': 'Bearer $token'};

  Uri _api(String endpoint) => Uri.parse('$base$endpoint');

  /// Direct play URL for a file. Path segments are percent-encoded but `/`
  /// separators are preserved, which is what OpenList's `/d/` route expects.
  Uri directUrl(String path) {
    final encoded = VfsPath.encode(path);
    return Uri.parse('$base/d$encoded');
  }

  @override
  Future<String> resolvePlayableUrl(String path) async => directUrl(path).toString();

  @override
  Future<bool> check() async {
    final res = await _client.post(_api('/api/fs/list'),
        headers: <String, String>{'Content-Type': 'application/json', ..._headers},
        body: jsonEncode({'path': '/', 'password': password, 'page': 1, 'per_page': 1, 'refresh': false}),
        ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final code = j['code'];
    if (code is num && code != 200) throw StateError('${j['message'] ?? 'OpenList error $code'}');
    return true;
  }

  @override
  Future<List<VirtualFile>> list(String path) async {
    final p = VfsPath.normalize(path);
    final res = await _client.post(_api('/api/fs/list'),
        headers: <String, String>{'Content-Type': 'application/json', ..._headers},
        body: jsonEncode({'path': p, 'password': password, 'page': 1, 'per_page': 0, 'refresh': false}),
        ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) throw const FormatException('OpenList response is not an object');
    final code = decoded['code'];
    if (code is num && code != 200) {
      throw StateError('${decoded['message'] ?? 'OpenList error $code'}');
    }
    final data = decoded['data'];
    final content = data is Map && data['content'] is List ? data['content'] as List : const <Object?>[];
    final files = <VirtualFile>[];
    for (final e in content) {
      if (e is! Map<String, dynamic>) continue;
      final name = e['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final isDir = e['is_dir'] == true || e['isDir'] == true;
      final childPath = e['path']?.toString();
      final fullPath = childPath != null && childPath.isNotEmpty
          ? VfsPath.normalize(childPath)
          : VfsPath.join(p, name);
      final size = e['size'];
      final modifiedRaw = e['modified'];
      DateTime? modified;
      if (modifiedRaw is String) {
        modified = DateTime.tryParse(modifiedRaw);
      }
      files.add(VirtualFile(
        name: name,
        path: fullPath,
        isDir: isDir,
        size: size is num ? size.toInt() : null,
        modified: modified,
        thumbUrl: e['thumbnail']?.toString(),
      ));
    }
    files.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return files;
  }
}
