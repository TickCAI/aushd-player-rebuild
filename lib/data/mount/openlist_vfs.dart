import 'dart:convert';

import 'package:http/http.dart' as http;

import 'virtual_file_system.dart';

/// OpenList (an AList-compatible file-list program) storage backend.
///
/// OpenList unifies WebDAV / SMB / every cloud drive behind one HTTP gateway:
/// - directory listing: `POST /api/fs/list` with `{path, password}`
/// - signed play URL:   `POST /api/fs/get` -> `data.raw_url`
///
/// Auth notes (verified against a real OpenList server):
/// - the login endpoint is `POST /api/auth/login` -> `data.token`
/// - API calls send the token **raw**: `Authorization: <token>` (NOT `Bearer`)
/// - `/d/<path>` needs `sign`+`expire` and returns "401 expire missing" when
///   called bare, so playback uses the signed `raw_url` from `/api/fs/get`.
/// - the REST API lives at the server root; a trailing `/dav` in the configured
///   URL is the WebDAV endpoint and is stripped before building API paths.
final class OpenListVfs implements VirtualFileSystem {
  OpenListVfs({
    required String baseUrl,
    String token = '',
    this.username = '',
    this.password = '',
    http.Client? client,
    String? id,
  })  : base = _base(baseUrl),
        _client = client ?? http.Client(),
        _token = token,
        id = id ?? 'openlist:${_base(baseUrl)}';

  /// Strip trailing slashes and a trailing `/dav` (the WebDAV endpoint is not
  /// the REST API base). Keeps any genuine reverse-proxy subpath intact.
  static String _base(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/dav')) {
      u = u.substring(0, u.length - 4);
      while (u.endsWith('/')) {
        u = u.substring(0, u.length - 1);
      }
    }
    return u;
  }

  /// Log in with username + password and return the token OpenList issues.
  /// Used by the settings wizard so the user only types a normal account, not
  /// a raw token. Returns '' on failure (never throws) — an empty token still
  /// works for public instances.
  static Future<String> authenticate(String baseUrl, String username, String password,
      {http.Client? client}) async {
    if (username.trim().isEmpty || password.isEmpty) return '';
    final c = client ?? http.Client();
    try {
      final res = await c
          .post(Uri.parse('${_base(baseUrl)}/api/auth/login'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'username': username.trim(), 'password': password}))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return '';
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return '';
      if (decoded['code'] is num && decoded['code'] != 200) return '';
      final data = decoded['data'];
      if (data is Map && data['token'] is String) return data['token'] as String;
      if (decoded['token'] is String) return decoded['token'] as String;
      return '';
    } catch (_) {
      return '';
    }
  }

  @override
  final String id;

  /// REST API base (server root, without a trailing `/dav`).
  final String base;
  final String username;
  final String password;
  final http.Client _client;

  /// Mutable so a lazy login can fill it when the wizard could not (e.g. the
  /// stream page is opened directly from search without a prior catalog scan).
  String _token;

  @override
  String get displayName => 'OpenList';

  /// OpenList expects the raw token, not an OAuth-style `Bearer` prefix.
  Map<String, String> get _headers => _token.isEmpty ? const {} : {'Authorization': _token};

  Uri _api(String endpoint) => Uri.parse('$base$endpoint');

  /// Log in lazily if we have credentials but no token yet. Never throws.
  Future<void> ensureToken() async {
    if (_token.isNotEmpty || username.trim().isEmpty || password.isEmpty) return;
    try {
      _token = await authenticate(base, username, password, client: _client);
    } catch (_) {
      _token = '';
    }
  }

  /// Fallback direct URL (works only on public instances without signing).
  /// Kept public for tests and as a last resort when `/api/fs/get` fails.
  Uri directUrl(String path) {
    final encoded = VfsPath.encode(path);
    return Uri.parse('$base/d$encoded');
  }

  /// Resolve a signed, Range-capable play URL via `POST /api/fs/get`.
  /// Falls back to the bare `/d/` URL for public instances.
  @override
  Future<String> resolvePlayableUrl(String path) async {
    final raw = await getRaw(path);
    return raw ?? directUrl(path).toString();
  }

  /// Fetch `data.raw_url` for a file — a signed direct link that needs no auth
  /// header and supports HTTP Range (what mpv/media3 need).
  Future<String?> getRaw(String path) async {
    await ensureToken();
    final p = VfsPath.normalize(path);
    try {
      final res = await _client
          .post(_api('/api/fs/get'),
              headers: <String, String>{'Content-Type': 'application/json', ..._headers},
              body: jsonEncode({'path': p, 'password': ''}))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['code'] is num && decoded['code'] != 200) return null;
      final data = decoded['data'];
      if (data is Map && data['raw_url'] is String && (data['raw_url'] as String).isNotEmpty) {
        return data['raw_url'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> check() async {
    await ensureToken();
    final res = await _client.post(_api('/api/fs/list'),
        headers: <String, String>{'Content-Type': 'application/json', ..._headers},
        body: jsonEncode({'path': '/', 'password': '', 'page': 1, 'per_page': 1, 'refresh': false}),
        ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final code = j['code'];
    if (code is num && code != 200) throw StateError('${j['message'] ?? 'OpenList error $code'}');
    return true;
  }

  @override
  Future<List<VirtualFile>> list(String path) async {
    await ensureToken();
    final p = VfsPath.normalize(path);
    final res = await _client.post(_api('/api/fs/list'),
        headers: <String, String>{'Content-Type': 'application/json', ..._headers},
        body: jsonEncode({'path': p, 'password': '', 'page': 1, 'per_page': 0, 'refresh': false}),
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
