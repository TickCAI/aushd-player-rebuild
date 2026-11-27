import 'dart:convert';
import 'dart:io';

import 'virtual_file_system.dart';

/// Minimal FTP backend implemented on raw [Socket]s — no native library and no
/// pub dependency. Supports the subset needed to browse and play:
///
/// - login (USER/PASS, optional passive-mode EPSV/PASV)
/// - directory listing via MLSD (preferred) with a LIST fallback
/// - direct play URL `ftp://user:pass@host/path` handed to mpv/libavformat
///
/// Honest limits: FTPS (explicit AUTH TLS) and active mode are not implemented;
/// passive mode is the norm on modern servers. Android's Media3 cannot play
/// ftp:// directly — desktop (mpv) is the supported target.
final class FtpVfs implements VirtualFileSystem {
  FtpVfs({
    required String baseUrl,
    this.username = '',
    this.password = '',
    String? id,
  })  : endpoint = _parse(baseUrl),
        id = id ?? 'ftp:${_parse(baseUrl).host}';

  static _Endpoint _parse(String url) {
    var u = url.trim();
    if (u.startsWith('ftp://')) u = u.substring(6);
    final slash = u.indexOf('/');
    final authority = slash < 0 ? u : u.substring(0, slash);
    var initialPath = slash < 0 ? '' : u.substring(slash);
    if (initialPath.isEmpty) initialPath = '/';
    var host = authority;
    var port = 21;
    final colon = authority.lastIndexOf(':');
    if (colon > 0) {
      final parsed = int.tryParse(authority.substring(colon + 1));
      if (parsed != null) {
        host = authority.substring(0, colon);
        port = parsed;
      }
    }
    return _Endpoint(host, port, initialPath);
  }

  @override
  final String id;
  final _Endpoint endpoint;
  final String username;
  final String password;

  @override
  String get displayName => 'FTP';

  /// The server-side path = share root from the base URL + the VFS path.
  String _serverPath(String path) {
    final root = VfsPath.normalize(endpoint.initialPath);
    final rel = VfsPath.normalize(path);
    if (root == '/') return rel;
    if (rel == '/') return root;
    return '$root$rel';
  }

  Uri _playUri(String path) {
    final uri = Uri(scheme: 'ftp', host: endpoint.host, port: endpoint.port, path: _serverPath(path));
    if (username.isEmpty && password.isEmpty) return uri;
    return uri.replace(
        userInfo: '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}');
  }

  @override
  Future<String> resolvePlayableUrl(String path) async => _playUri(path).toString();

  @override
  Future<bool> check() async {
    final c = await _connect();
    try {
      await c.quit();
      return true;
    } finally {
      c.close();
    }
  }

  @override
  Future<List<VirtualFile>> list(String path) async {
    final p = VfsPath.normalize(path);
    final c = await _connect();
    late final List<_FtpEntry> entries;
    try {
      await c.cwd(_serverPath(p));
      final listing = await c.list();
      entries = listing;
    } finally {
      c.close();
    }
    final files = <VirtualFile>[
      for (final e in entries)
        if (e.name.isNotEmpty && e.name != '.' && e.name != '..')
          VirtualFile(
            name: e.name,
            path: VfsPath.join(p, e.name),
            isDir: e.isDir,
            size: e.size,
            modified: e.modified,
          ),
    ];
    files.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return files;
  }

  Future<_FtpConnection> _connect() => _FtpConnection.open(endpoint, username, password);
}

final class _Endpoint {
  const _Endpoint(this.host, this.port, this.initialPath);

  final String host;
  final int port;
  final String initialPath;
}

final class _FtpEntry {
  const _FtpEntry(this.name, this.isDir, this.size, this.modified);

  final String name;
  final bool isDir;
  final int? size;
  final DateTime? modified;
}

/// One control connection. Reads replies line-by-line, opens a passive data
/// socket for LIST/MLSD, and parses both machine (MLSD) and Unix (LIST) formats.
final class _FtpConnection {
  _FtpConnection(this._socket);

  final Socket _socket;
  String _buffer = '';

  static Future<_FtpConnection> open(_Endpoint ep, String user, String pass) async {
    final socket = await Socket.connect(ep.host, ep.port, timeout: const Duration(seconds: 15));
    final c = _FtpConnection(socket);
    await c._expect([220]);
    await c._cmd('USER ${user.isEmpty ? 'anonymous' : user}', const [230, 331]);
    if (user.isNotEmpty) {
      final reply = await c._cmd('PASS $pass', const [230, 202]);
      if (!reply.$1) {
        socket.destroy();
        throw StateError('FTP login rejected');
      }
    }
    await c._cmd('TYPE I', const [200]);
    if (ep.initialPath != '/') {
      await c._cmd('CWD ${ep.initialPath}', const [250]);
    }
    return c;
  }

  Future<(bool, String)> _cmd(String line, List<int> okCodes) async {
    _socket.writeln(line);
    return _expect(okCodes);
  }

  Future<(bool, String)> _expect(List<int> okCodes) async {
    final sb = StringBuffer();
    while (true) {
      final line = await _readLine();
      if (line.isEmpty) continue;
      sb.writeln(line);
      if (line.length < 3 || int.tryParse(line.substring(0, 3)) == null) continue;
      // A line like "220 ready" is final when the 4th char is a space; a '-'
      // means a multiline reply continues.
      if (line.length > 3 && line[3] == '-') continue;
      final code = int.parse(line.substring(0, 3));
      return (okCodes.contains(code), sb.toString().trim());
    }
  }

  Future<String> _readLine() async {
    while (true) {
      final nl = _buffer.indexOf('\n');
      if (nl >= 0) {
        final line = _buffer.substring(0, nl).replaceAll('\r', '');
        _buffer = _buffer.substring(nl + 1);
        return line;
      }
      final chunk = await _socket.first.timeout(const Duration(seconds: 20));
      _buffer += utf8.decode(chunk, allowMalformed: true);
    }
  }

  Future<void> cwd(String path) async {
    final ok = await _cmd('CWD $path', const [250]);
    if (!ok.$1) throw StateError('FTP CWD $path failed: ${ok.$2}');
  }

  /// Ask for a passive data port, connect to it, then run a listing command.
  Future<List<_FtpEntry>> list() async {
    final port = await _passivePort();
    final data = await Socket.connect(_socket.remoteAddress.address, port,
        timeout: const Duration(seconds: 15));
    final bytes = <int>[];
    final done = data.listen(bytes.addAll).asFuture<void>();
    // Prefer machine-readable MLSD; fall back to Unix LIST.
    var reply = await _cmd('MLSD', const [150, 125, 226]);
    if (!reply.$1) {
      await done;
      data.destroy();
      // The 150/226 final reply may already have been consumed; LIST opens a
      // fresh data socket.
      final port2 = await _passivePort();
      final data2 = await Socket.connect(_socket.remoteAddress.address, port2,
          timeout: const Duration(seconds: 15));
      final bytes2 = <int>[];
      final done2 = data2.listen(bytes2.addAll).asFuture<void>();
      reply = await _cmd('LIST', const [150, 125, 226]);
      await Future.any([done2, Future.delayed(const Duration(seconds: 20))]);
      data2.destroy();
      // Drain the final 226 reply left in the control buffer.
      await _drainFinal();
      return _parseUnix(utf8.decode(bytes2, allowMalformed: true));
    }
    await Future.any([done, Future.delayed(const Duration(seconds: 20))]);
    data.destroy();
    await _drainFinal();
    return _parseMlsd(utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _drainFinal() async {
    // Best-effort: consume a trailing 226 reply line so the next command stays
    // in sync. _readLine uses the same buffer as _expect, so no bytes are lost.
    try {
      await _readLine().timeout(const Duration(milliseconds: 400));
    } catch (_) {}
  }

  Future<int> _passivePort() async {
    var reply = await _cmd('EPSV', const [229]);
    if (reply.$1) {
      final m = RegExp(r'\(\|\|(\d+)\|\)').firstMatch(reply.$2);
      if (m != null) return int.parse(m.group(1)!);
    }
    reply = await _cmd('PASV', const [227]);
    if (!reply.$1) throw StateError('FTP passive mode failed: ${reply.$2}');
    final m = RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(reply.$2);
    if (m == null) throw StateError('FTP PASV reply unparsable');
    return (int.parse(m.group(5)!) << 8) | int.parse(m.group(6)!);
  }

  List<_FtpEntry> _parseMlsd(String text) {
    final out = <_FtpEntry>[];
    for (final line in text.split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      final sep = l.indexOf(';');
      if (sep < 0) continue;
      final facts = l.substring(0, sep).split(';');
      final name = l.substring(sep + 1).trim();
      var isDir = false;
      int? size;
      DateTime? modified;
      for (final f in facts) {
        final kv = f.split('=');
        if (kv.length != 2) continue;
        switch (kv[0].trim().toLowerCase()) {
          case 'type':
            isDir = kv[1].trim().toLowerCase() == 'dir';
            break;
          case 'size':
            size = int.tryParse(kv[1].trim());
            break;
          case 'modify':
            modified = DateTime.tryParse(kv[1].trim());
            break;
        }
      }
      out.add(_FtpEntry(name, isDir, size, modified));
    }
    return out;
  }

  List<_FtpEntry> _parseUnix(String text) {
    final out = <_FtpEntry>[];
    final re = RegExp(r'^([d\-l])([rwxst\-]{9})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w+\s+\d+\s+[\d:]+)\s+(.+)$');
    for (final line in text.split('\n')) {
      final m = re.firstMatch(line.trim());
      if (m == null) continue;
      final isDir = m.group(1) == 'd';
      final size = int.tryParse(m.group(3)!);
      // Names may contain spaces; group(5) is everything after the date.
      var name = m.group(5)!.trim();
      final arrow = name.indexOf(' -> ');
      if (arrow > 0) name = name.substring(0, arrow);
      out.add(_FtpEntry(name, isDir, size, null));
    }
    return out;
  }

  Future<void> quit() async {
    try {
      await _cmd('QUIT', const [221]);
    } catch (_) {}
  }

  void close() => _socket.destroy();
}
