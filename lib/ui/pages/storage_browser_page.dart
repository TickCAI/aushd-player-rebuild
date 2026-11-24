import 'package:flutter/material.dart';

import '../../data/mount/mount_service.dart';
import '../../data/mount/virtual_file_system.dart';
import '../../l10n/l10n.dart';
import '../core/navigation.dart';
import '../core/playback_launcher.dart';
import '../core/ui_sounds.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';

/// A TV-friendly browser for a configured [MountDefinition]. Directories are
/// navigated in-place; selecting a file resolves a playable URL through the
/// backend and hands it to the direct-play path (mpv / media3).
class StorageBrowserPage extends StatefulWidget {
  const StorageBrowserPage({super.key, required this.mount});

  final MountDefinition mount;

  @override
  State<StorageBrowserPage> createState() => _StorageBrowserPageState();
}

class _StorageBrowserPageState extends State<StorageBrowserPage> {
  late final VirtualFileSystem _vfs;
  final List<String> _stack = ['/'];
  List<VirtualFile>? _files;
  String? _error;
  bool _loading = false;

  String get _path => _stack.last;

  @override
  void initState() {
    super.initState();
    _vfs = widget.mount.toVfs();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await _vfs.list(_path);
      if (mounted) setState(() => _files = files);
    } catch (e) {
      debugPrint('[storage] list $_path failed: $e');
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _enter(VirtualFile file) {
    if (!file.isDir) return;
    setState(() {
      final next = VfsPath.join(_path, file.name);
      if (_stack.last != next) _stack.add(next);
      _files = null;
    });
    _load();
  }

  void _pop() {
    if (_stack.length == 1) return;
    setState(() {
      _stack.removeLast();
      _files = null;
    });
    _load();
  }

  Future<void> _play(VirtualFile file) async {
    try {
      final url = await _vfs.resolvePlayableUrl(file.path);
      if (!mounted) return;
      await playDirectUrl(context, url, title: file.name);
    } catch (e) {
      debugPrint('[storage] resolve ${file.path} failed: $e');
      if (mounted) {
        UiSounds.play(UiSound.error);
        showToast(context, context.l10n.storagePlayFailed('$e'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final files = _files;
    return BackHandler(
      onBack: () {
        if (_stack.length > 1) {
          _pop();
          return true;
        }
        return false;
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: contentLeft, top: 64, right: 120, bottom: 12),
          child: Row(children: [
            Icon(Icons.folder_special_rounded, size: 44, color: Zc.accent),
            const SizedBox(width: 18),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.mount.name, style: Zt.headline),
                const SizedBox(height: 4),
                Text(_path == '/' ? l10n.storageRoot : _path,
                    style: Zt.body.copyWith(color: Zc.textMuted)),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.only(left: contentLeft, top: 24, right: 120),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.storageLoadFailed, style: Zt.title.copyWith(color: Zc.danger)),
                    const SizedBox(height: 8),
                    Text(_error!, style: Zt.caption.copyWith(color: Zc.textFaint)),
                    const SizedBox(height: 20),
                    TvFocusable(
                      onSelect: _load,
                      builder: (_, focused) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        decoration: BoxDecoration(
                          color: focused ? Colors.white : Zc.surface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(l10n.retry,
                            style: Zt.label.copyWith(color: focused ? Zc.background : Zc.text)),
                      ),
                    ),
                  ]),
                )
              : files == null
                  ? const Center(child: CircularProgressIndicator())
                  : files.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(left: contentLeft, top: 24),
                          child: Text(l10n.storageEmpty, style: Zt.body),
                        )
                      : FocusZone(
                          debugLabel: 'storage-browser',
                          child: GridView.builder(
                            clipBehavior: Clip.hardEdge,
                            padding: const EdgeInsets.fromLTRB(contentLeft, 8, 120, 120),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 320,
                              mainAxisSpacing: 22,
                              crossAxisSpacing: 22,
                              childAspectRatio: 3.4,
                            ),
                            itemCount: files.length,
                            itemBuilder: (context, i) => _fileTile(context, files[i]),
                          ),
                        ),
        ),
      ]),
    );
  }

  Widget _fileTile(BuildContext context, VirtualFile file) {
    final icon = file.isDir
        ? Icons.folder_rounded
        : _isVideo(file.name)
            ? Icons.movie_outlined
            : Icons.insert_drive_file_outlined;
    return TvFocusable(
      autofocus: false,
      onSelect: () => file.isDir ? _enter(file) : _play(file),
      builder: (context, focused) => AnimatedContainer(
        duration: Zm.fast,
        decoration: BoxDecoration(
          color: focused ? Colors.white : Zc.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: focused ? Colors.white : Zc.outline, width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(children: [
          Icon(icon, size: 30, color: focused ? Zc.background : (file.isDir ? Zc.accent : Zc.textMuted)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Zt.label.copyWith(color: focused ? Zc.background : Zc.text)),
              const SizedBox(height: 4),
              Text(file.isDir ? context.l10n.storageFolder : _sizeLabel(file.size),
                  style: Zt.caption.copyWith(color: focused ? Colors.black54 : Zc.textFaint)),
            ]),
          ),
          if (!file.isDir) Icon(Icons.play_arrow_rounded, size: 24, color: focused ? Zc.background : Zc.textFaint),
        ]),
      ),
    );
  }

  static bool _isVideo(String name) {
    final ext = name.split('.').last.toLowerCase();
    const video = {'mp4', 'mkv', 'avi', 'mov', 'ts', 'm4v', 'webm', 'flv', 'wmv', 'rmvb', 'iso'};
    return video.contains(ext);
  }

  String _sizeLabel(int? size) {
    if (size == null) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
