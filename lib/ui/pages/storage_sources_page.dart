import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../data/mount/mount_service.dart';
import '../../data/mount/openlist_vfs.dart';
import '../../l10n/l10n.dart';
import '../core/navigation.dart';
import '../core/ui_sounds.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import '../widgets/setting_rows.dart';
import '../widgets/side_panel.dart';
import 'storage_browser_page.dart';

/// Manage network storage sources (OpenList / WebDAV).
///
/// Reached from Settings → Services. Each source can be tested, edited,
/// removed, or opened in the file browser. Credentials stay local; cloud sync
/// (a later phase) will deliberately exclude them.
class StorageSourcesPage extends StatefulWidget {
  const StorageSourcesPage({super.key});

  @override
  State<StorageSourcesPage> createState() => _StorageSourcesPageState();
}

class _StorageSourcesPageState extends State<StorageSourcesPage> {
  AppServices? _services;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _services ??= AppServicesScope.read(context);
  }

  Future<void> _add() async {
    final l10n = context.l10n;
    // The dropdown lists concrete protocols/brands. Vendor drives are really
    // OpenList gateway presets (see ProtocolPreset) — selecting one just
    // pre-labels an OpenList source.
    final preset = await showSidePanel<ProtocolPreset>(
      context,
      title: l10n.storagePickKind,
      options: [
        for (final p in ProtocolPreset.all)
          PanelOption(
            value: p,
            title: p.label,
            subtitle: p.hint.isEmpty
                ? (p.kind == MountKind.openlist
                    ? l10n.storageKindOpenlistHint
                    : p.kind == MountKind.webdav
                        ? l10n.storageKindWebdavHint
                        : l10n.storageKindFtpHint)
                : p.hint,
            selected: p == ProtocolPreset.all.first,
          ),
      ],
    );
    if (preset == null || !mounted) return;
    final mount = await _editFlow(MountDefinition(
      id: 'mount-${DateTime.now().microsecondsSinceEpoch}',
      kind: preset.kind,
      name: preset.label,
      baseUrl: '',
    ));
    if (mount == null || !mounted) return;
    await _services!.mountService.add(mount);
    if (mounted) setState(() {});
  }

  /// Sequential text dialogs: name → address → username → password. All
  /// protocols use the same credential shape (address + username + password);
  /// OpenList exchanges username/password for a bearer token automatically, so
  /// the user never has to find a raw token. Returns null on cancel.
  Future<MountDefinition?> _editFlow(MountDefinition start) async {
    final l10n = context.l10n;
    var m = start;
    final name = await showTextInputDialog(context, title: l10n.storageNameTitle, initial: m.name, hint: l10n.storageNameHint);
    if (name == null || !mounted) return null;
    m = MountDefinition(
      id: m.id, kind: m.kind,
      name: name.trim().isEmpty ? m.name : name.trim(),
      baseUrl: m.baseUrl, token: m.token, username: m.username, password: m.password,
    );
    final urlHint = switch (m.kind) {
      MountKind.openlist => 'https://list.example.com',
      MountKind.webdav => 'https://host/dav',
      MountKind.ftp => 'ftp://host:21/folder',
    };
    final url = await showTextInputDialog(context, title: l10n.storageUrlTitle, initial: m.baseUrl, hint: urlHint);
    if (url == null || url.trim().isEmpty || !mounted) return null;
    m = MountDefinition(
      id: m.id, kind: m.kind, name: m.name, baseUrl: url.trim(),
      token: m.token, username: m.username, password: m.password,
    );
    final user = await showTextInputDialog(
      context, title: l10n.storageUserTitle,
      initial: m.username, hint: l10n.storageUserHint,
    );
    if (user == null || !mounted) return null;
    final pass = await showTextInputDialog(
      context, title: l10n.storagePasswordTitle, initial: m.password,
    );
    if (pass == null || !mounted) return null;

    // OpenList: log in once with username/password to obtain a bearer token.
    // On failure (public instance / wrong creds) keep going with an empty
    // token — the user can still browse public content, and _test will tell
    // them something is wrong.
    var token = '';
    if (m.kind == MountKind.openlist && user.trim().isNotEmpty) {
      token = await OpenListVfs.authenticate(m.baseUrl, user.trim(), pass);
    }
    return MountDefinition(
      id: m.id, kind: m.kind, name: m.name, baseUrl: m.baseUrl,
      token: token, username: user.trim(), password: pass,
    );
  }

  Future<void> _edit(MountDefinition m) async {
    final next = await _editFlow(m);
    if (next == null || !mounted) return;
    await _services!.mountService.add(next);
    if (mounted) setState(() {});
  }

  Future<void> _test(MountDefinition m) async {
    final l10n = context.l10n;
    try {
      await m.toVfs().check();
      if (!mounted) return;
      UiSounds.play(UiSound.select);
      showToast(context, l10n.connected);
    } catch (e) {
      if (!mounted) return;
      UiSounds.play(UiSound.error);
      showToast(context, l10n.storageTestFailed('$e'));
    }
  }

  Future<void> _remove(MountDefinition m) async {
    final l10n = context.l10n;
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Zc.surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Zs.radiusLarge)),
        child: SizedBox(
          width: 720,
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: FocusZone(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l10n.storageRemoveTitle, style: Zt.headline),
                const SizedBox(height: 14),
                Text(m.name, style: Zt.body),
                const SizedBox(height: 30),
                Row(children: [
                  TvButton(label: l10n.delete, icon: Icons.delete_outline_rounded, primary: true,
                      onSelect: () => Navigator.of(context).pop(true)),
                  const SizedBox(width: 16),
                  TvButton(label: l10n.cancel, onSelect: () => Navigator.of(context).pop(false)),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
    if (yes != true || !mounted) return;
    await _services!.mountService.remove(m.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mounts = _services?.mountService.mounts ?? const <MountDefinition>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: contentLeft, top: 64, right: 120, bottom: 8),
        child: Text(l10n.storageSources, style: Zt.headline),
      ),
      Padding(
        padding: const EdgeInsets.only(left: contentLeft, right: 120, bottom: 22),
        child: Text(l10n.storageIntro, style: Zt.body.copyWith(color: Zc.textMuted)),
      ),
      Padding(
        padding: const EdgeInsets.only(left: contentLeft, right: 120, bottom: 26),
        child: SettingActionRow(
          title: l10n.storageAddSource,
          subtitle: l10n.storageAddHint,
          icon: Icons.add_circle_outline_rounded,
          onSelect: _add,
        ),
      ),
      Expanded(
        child: mounts.isEmpty
            ? Padding(
                padding: const EdgeInsets.only(left: contentLeft, top: 24),
                child: Text(l10n.storageNoneYet, style: Zt.body.copyWith(color: Zc.textFaint)),
              )
            : ListView(
                padding: EdgeInsets.fromLTRB(contentLeft, 0, 120, MediaQuery.sizeOf(context).height * 0.3),
                children: [for (final m in mounts) _sourceRow(m)],
              ),
      ),
    ]);
  }

  Widget _sourceRow(MountDefinition m) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(color: Zc.surface, borderRadius: BorderRadius.circular(18)),
        padding: const EdgeInsets.fromLTRB(26, 20, 26, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(switch (m.kind) {
                  MountKind.openlist => Icons.cloud_outlined,
                  MountKind.webdav => Icons.cloud_queue_outlined,
                  MountKind.ftp => Icons.folder_shared_outlined,
                },
                size: 34, color: Zc.accent),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.name, style: Zt.label.copyWith(fontSize: 24)),
                const SizedBox(height: 4),
                Text(m.baseUrl, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: Zt.caption.copyWith(color: Zc.textFaint)),
              ]),
            ),
            Text(m.kind.name.toUpperCase(), style: Zt.caption.copyWith(color: Zc.textMuted)),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 10, children: [
            _miniButton(l10n.storageOpen, Icons.folder_open_rounded,
                () => Navigator.of(context).push(tvRoute(StorageBrowserPage(mount: m), name: 'storage:${m.id}'))),
            _miniButton(l10n.testConnection, Icons.wifi_tethering_rounded, () => _test(m)),
            _miniButton(l10n.edit, Icons.edit_outlined, () => _edit(m)),
            _miniButton(l10n.delete, Icons.delete_outline_rounded, () => _remove(m)),
          ]),
        ]),
      ),
    );
  }

  Widget _miniButton(String label, IconData icon, VoidCallback onSelect) {
    return TvFocusable(
      onSelect: onSelect,
      builder: (context, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 22, color: focused ? Zc.background : Zc.textMuted),
          const SizedBox(width: 8),
          Text(label, style: Zt.label.copyWith(fontSize: 18, color: focused ? Zc.background : Zc.text)),
        ]),
      ),
    );
  }
}
