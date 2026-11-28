import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/local_store.dart';
import 'ftp_vfs.dart';
import 'openlist_vfs.dart';
import 'virtual_file_system.dart';
import 'webdav_vfs.dart';

/// The storage backends the app can talk to directly.
///
/// - [openlist]: OpenList / AList gateway — covers every cloud drive (阿里/百度/
///   115/夸克/OneDrive/Google Drive) plus SMB and WebDAV behind one HTTP API.
///   This is the recommended option for network drives.
/// - [webdav]: standard WebDAV share, direct.
/// - [ftp]: classic FTP / FTPS share, direct (pure Dart, no native library).
enum MountKind { openlist, webdav, ftp }

/// A user-facing protocol choice shown in the add-source dropdown. Brand
/// entries (阿里/百度/...) are really OpenList gateway presets — the app cannot
/// speak those vendor protocols itself, so [kind] is always [openlist] for them.
final class ProtocolPreset {
  const ProtocolPreset(this.label, this.kind, {this.hint = ''});

  final String label;
  final MountKind kind;
  final String hint;

  static const List<ProtocolPreset> all = [
    ProtocolPreset('OpenList / AList', MountKind.openlist),
    ProtocolPreset('WebDAV', MountKind.webdav),
    ProtocolPreset('FTP / FTPS', MountKind.ftp),
    ProtocolPreset('阿里云盘', MountKind.openlist, hint: '需先部署 OpenList'),
    ProtocolPreset('百度网盘', MountKind.openlist, hint: '需先部署 OpenList'),
    ProtocolPreset('115 网盘', MountKind.openlist, hint: '需先部署 OpenList'),
    ProtocolPreset('夸克网盘', MountKind.openlist, hint: '需先部署 OpenList'),
    ProtocolPreset('OneDrive', MountKind.openlist, hint: '需先部署 OpenList'),
    ProtocolPreset('Google Drive', MountKind.openlist, hint: '需先部署 OpenList'),
    ProtocolPreset('SMB / NAS', MountKind.openlist, hint: '需先部署 OpenList'),
  ];
}

/// A user-configured storage source. Credentials are persisted locally only
/// (never uploaded — cloud sync in a later phase will explicitly exclude
/// them). `id` is stable so browser pages can be cached/keyed by it.
@immutable
final class MountDefinition {
  const MountDefinition({
    required this.id,
    required this.kind,
    required this.name,
    required this.baseUrl,
    this.token = '',
    this.username = '',
    this.password = '',
  });

  final String id;
  final MountKind kind;
  final String name;
  final String baseUrl;
  final String token;
  final String username;
  final String password;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'baseUrl': baseUrl,
        'token': token,
        'username': username,
        'password': password,
      };

  static MountDefinition? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id']?.toString();
    final baseUrl = raw['baseUrl']?.toString();
    if (id == null || id.isEmpty || baseUrl == null || baseUrl.isEmpty) return null;
    final kind = MountKind.values.asNameMap()[raw['kind']?.toString()] ?? MountKind.openlist;
    return MountDefinition(
      id: id,
      kind: kind,
      name: raw['name']?.toString() ??
          (switch (kind) {
            MountKind.openlist => 'OpenList',
            MountKind.webdav => 'WebDAV',
            MountKind.ftp => 'FTP',
          }),
      baseUrl: baseUrl,
      token: raw['token']?.toString() ?? '',
      username: raw['username']?.toString() ?? '',
      password: raw['password']?.toString() ?? '',
    );
  }

  VirtualFileSystem toVfs() => switch (kind) {
        MountKind.openlist => OpenListVfs(
            baseUrl: baseUrl, token: token, username: username, password: password, id: id),
        MountKind.webdav => WebDavVfs(
            baseUrl: baseUrl, username: username, password: password, id: id),
        MountKind.ftp => FtpVfs(
            baseUrl: baseUrl, username: username, password: password, id: id),
      };
}

/// Owns the persisted list of storage sources.
///
/// Uses the same [LocalStore] abstraction as ConfigService so it is trivially
/// testable with an in-memory store and needs no new dependency. Notifies on
/// add/remove so the home entry and settings list refresh live.
final class MountService extends ChangeNotifier {
  MountService(this._store);

  static const _key = 'aushd.mounts.v1';
  final LocalStore _store;
  List<MountDefinition> _mounts = const [];

  List<MountDefinition> get mounts => List.unmodifiable(_mounts);
  bool get available => _mounts.isNotEmpty;

  Future<void> load() async {
    final raw = await _store.getString(_key);
    if (raw == null || raw.isEmpty) {
      _mounts = const [];
      return;
    }
    try {
      final decoded = jsonDecode(raw) as List;
      _mounts = [for (final e in decoded) MountDefinition.fromJson(e)].whereType<MountDefinition>().toList();
    } catch (_) {
      _mounts = const [];
    }
  }

  Future<void> _persist() async {
    await _store.setString(_key, jsonEncode([for (final m in _mounts) m.toJson()]));
  }

  Future<void> add(MountDefinition definition) async {
    final list = [..._mounts.where((m) => m.id != definition.id), definition];
    _mounts = list;
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _mounts = _mounts.where((m) => m.id != id).toList();
    await _persist();
    notifyListeners();
  }

  MountDefinition? byId(String id) {
    for (final m in _mounts) {
      if (m.id == id) return m;
    }
    return null;
  }

  VirtualFileSystem? vfsFor(String id) => byId(id)?.toVfs();
}
