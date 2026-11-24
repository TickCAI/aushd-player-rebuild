import 'package:flutter/foundation.dart';

/// One entry returned by a [VirtualFileSystem] directory listing.
///
/// Kept deliberately small and UI-agnostic: a browser page decides how to
/// render a file, the VFS only reports what the storage backend told us.
@immutable
final class VirtualFile {
  const VirtualFile({
    required this.name,
    required this.path,
    required this.isDir,
    this.size,
    this.modified,
    this.thumbUrl,
  });

  /// Display name (file or directory base name).
  final String name;

  /// Backend-absolute path, always starting with `/` and using forward slashes.
  final String path;

  final bool isDir;

  final int? size;

  final DateTime? modified;

  /// Optional poster/thumbnail URL for image/video files, when the backend
  /// exposes one. Discovery metadata enrichment can use it later.
  final String? thumbUrl;

  @override
  String toString() => 'VirtualFile($path, dir=$isDir, size=$size)';
}

/// A storage backend that can browse directories and hand out a playable URL.
///
/// OpenList is the primary implementation; WebDAV is a lighter fallback for
/// users who do not run OpenList. SMB is intentionally NOT implemented here —
/// Dart has no mature SMB client, and OpenList already bridges SMB shares.
abstract interface class VirtualFileSystem {
  /// Stable id, used to key persisted mount definitions and cache entries.
  String get id;

  /// Human-readable label shown in the storage-source settings page.
  String get displayName;

  /// List the immediate children of [path]. `path` is normalised by the
  /// implementation; `/` means the backend root.
  Future<List<VirtualFile>> list(String path);

  /// Return a URL the existing mpv/media3 backend can load directly.
  /// For OpenList this is `/d/<path>` (optionally signed); for WebDAV it is the
  /// file's own HTTP(S) URL with credentials embedded.
  Future<String> resolvePlayableUrl(String path);

  /// Cheap connectivity/credential probe. Throws on failure, returns true on
  /// success, so callers can show a single "connected / problem" toast.
  Future<bool> check();
}

/// Path helpers shared by all VFS implementations.
///
/// Backend paths (OpenList and WebDAV alike) are POSIX-like: leading `/`,
/// forward slashes only, no `.`/`..` segments, no trailing slash except root.
final class VfsPath {
  const VfsPath._();

  /// Normalise an arbitrary user/backend path into a canonical backend path.
  ///
  /// - backslashes become `/`
  /// - duplicate slashes collapse
  /// - `.` is dropped, `..` pops the previous segment (never above root)
  /// - result always starts with `/` and has no trailing slash (except `/`)
  static String normalize(String input) {
    final raw = input.trim().replaceAll(r'\', '/');
    final segments = <String>[];
    for (final part in raw.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return segments.isEmpty ? '/' : '/${segments.join('/')}';
  }

  /// Join a parent directory and a child name into a canonical path.
  static String join(String parent, String name) => normalize('${normalize(parent)}/$name');

  /// Base name of a canonical path (`/` returns `/`).
  static String basename(String path) {
    final p = normalize(path);
    if (p == '/') return '/';
    return p.substring(p.lastIndexOf('/') + 1);
  }

  /// Parent directory of a canonical path (`/` returns `/`).
  static String dirname(String path) {
    final p = normalize(path);
    if (p == '/') return '/';
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  /// Percent-encode each path segment while keeping `/` separators.
  static String encode(String path) {
    final p = normalize(path);
    if (p == '/') return '/';
    return p.split('/').map(Uri.encodeComponent).join('/');
  }
}
