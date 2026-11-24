import 'dart:convert';

import 'package:http/http.dart' as http;

import 'virtual_file_system.dart';

/// Minimal WebDAV backend using `PROPFIND` for directory listing.
///
/// This is a fallback for users who expose a WebDAV share directly instead of
/// going through OpenList. Only `resourcetype`, `getcontentlength` and
/// `getlastmodified` are parsed — enough to browse and hand a direct URL to
/// mpv. Many servers require Basic auth, embedded into the playable URL so the
/// native player can authenticate without header support.
final class WebDavVfs implements VirtualFileSystem {
  WebDavVfs({
    required String baseUrl,
    this.username = '',
    this.password = '',
    http.Client? client,
    String? id,
  })  : base = _base(baseUrl),
        _client = client ?? http.Client(),
        id = id ?? 'webdav:${_base(baseUrl)}';

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
  final String username;
  final String password;
  final http.Client _client;

  @override
  String get displayName => 'WebDAV';

  Map<String, String> get _headers {
    final h = <String, String>{'Depth': '1'};
    if (username.isNotEmpty || password.isNotEmpty) {
      h['Authorization'] = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    }
    return h;
  }

  Uri _url(String path) => Uri.parse('$base${VfsPath.encode(path)}');

  @override
  Future<String> resolvePlayableUrl(String path) async {
    final uri = _url(path);
    if (username.isEmpty && password.isEmpty) return uri.toString();
    // Embed credentials so the native player (mpv) can authenticate.
    return uri.replace(userInfo: '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}').toString();
  }

  @override
  Future<bool> check() async {
    final res = await _client.send(http.Request('PROPFIND', _url('/'))..headers.addAll(_headers)).timeout(const Duration(seconds: 15));
    if (res.statusCode < 200 || res.statusCode >= 300) throw StateError('HTTP ${res.statusCode}');
    return true;
  }

  @override
  Future<List<VirtualFile>> list(String path) async {
    final p = VfsPath.normalize(path);
    final request = http.Request('PROPFIND', _url(p))..headers.addAll(_headers);
    final res = await _client.send(request).timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) throw StateError('HTTP ${res.statusCode}');
    final body = await res.stream.bytesToString();
    final responses = _parseMultistatus(body);
    final files = <VirtualFile>[];
    final rootHref = _hrefPath(_url(p).path);
    for (final entry in responses) {
      final hrefPath = _hrefPath(entry.$1);
      if (hrefPath == rootHref) continue; // skip the collection itself
      final isDir = entry.$2 == 'collection';
      final name = VfsPath.basename(hrefPath);
      if (name.isEmpty) continue;
      files.add(VirtualFile(
        name: name,
        path: hrefPath,
        isDir: isDir,
        size: entry.$3,
        modified: entry.$4,
      ));
    }
    files.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return files;
  }

  /// Very small XML reader for the handful of DAV properties we need.
  /// Avoids pulling an XML dependency into the app for a fallback backend.
  List<(String, String?, int?, DateTime?)> _parseMultistatus(String body) {
    final out = <(String, String?, int?, DateTime?)>[];
    final responseRe = RegExp(r'<(?:\w+:)?response\b[^>]*>(.*?)</(?:\w+:)?response>', dotAll: true, caseSensitive: false);
    for (final m in responseRe.allMatches(body)) {
      final block = m.group(1) ?? '';
      final href = _tag(block, 'href');
      if (href == null) continue;
      final isCollection = RegExp(r'<(?:\w+:)?collection\s*/\s*>', caseSensitive: false).hasMatch(block);
      final lengthRaw = _tag(block, 'getcontentlength');
      final size = lengthRaw == null ? null : int.tryParse(lengthRaw);
      final modifiedRaw = _tag(block, 'getlastmodified');
      final modified = modifiedRaw == null ? null : DateTime.tryParse(modifiedRaw);
      out.add((href, isCollection ? 'collection' : null, size, modified));
    }
    return out;
  }

  String? _tag(String block, String name) {
    final m = RegExp(r'<(?:\w+:)?' + name + r'\b[^>]*>(.*?)</(?:\w+:)?' + name + r'\s*>',
            dotAll: true, caseSensitive: false)
        .firstMatch(block);
    return m?.group(1)?.trim();
  }

  String _hrefPath(String href) {
    var h = href;
    // Absolute URLs: keep only the path portion.
    final uri = Uri.tryParse(h);
    if (uri != null && uri.hasScheme) h = uri.path;
    h = Uri.decodeFull(h);
    return VfsPath.normalize(h);
  }
}
