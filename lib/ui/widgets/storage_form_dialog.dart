import 'package:flutter/material.dart';

import '../../data/mount/mount_service.dart';
import '../../data/mount/mount_url.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'setting_rows.dart';

/// Result of the unified storage-source form.
final class StorageFormResult {
  const StorageFormResult({
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  final String name;
  final String baseUrl;
  final String username;
  final String password;
}

/// One dialog to configure a storage source: display name, protocol dropdown,
/// host, port, optional path, username and password. The port is merged into
/// [baseUrl] by [buildMountUrl], so callers keep a single URL field.
///
/// Returns null on cancel.
Future<StorageFormResult?> showStorageFormDialog(
  BuildContext context, {
  required MountKind kind,
  String name = '',
  String baseUrl = '',
  String username = '',
  String password = '',
}) {
  return showDialog<StorageFormResult>(
    context: context,
    builder: (_) => _StorageFormDialog(
      kind: kind,
      name: name,
      baseUrl: baseUrl,
      username: username,
      password: password,
    ),
  );
}

class _StorageFormDialog extends StatefulWidget {
  const _StorageFormDialog({
    required this.kind,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  final MountKind kind;
  final String name;
  final String baseUrl;
  final String username;
  final String password;

  @override
  State<_StorageFormDialog> createState() => _StorageFormDialogState();
}

class _StorageFormDialogState extends State<_StorageFormDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _path;
  late final TextEditingController _user = TextEditingController(text: widget.username);
  late final TextEditingController _pass = TextEditingController(text: widget.password);
  late String _protocol;

  @override
  void initState() {
    super.initState();
    final parsed = parseMountUrl(widget.baseUrl);
    _protocol = switch (widget.kind) {
      MountKind.ftp => 'ftp',
      _ => (parsed.protocol == 'ftp' ? 'ftp' : parsed.protocol),
    };
    _host = TextEditingController(text: parsed.host);
    _port = TextEditingController(text: parsed.port);
    _path = TextEditingController(text: parsed.path);
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Map<String, String> _protocols(L10n l) => {
        'http': l.storageProtocolHttp,
        'https': l.storageProtocolHttps,
        'ftp': l.storageProtocolFtp,
      };

  void _save() {
    final baseUrl = buildMountUrl(
      protocol: _protocol,
      host: _host.text,
      port: _port.text,
      path: _path.text,
    );
    Navigator.of(context).pop(StorageFormResult(
      name: _name.text.trim(),
      baseUrl: baseUrl,
      username: _user.text.trim(),
      password: _pass.text,
    ));
  }

  Widget _field(String label, TextEditingController controller,
      {String? hint, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Zt.label.copyWith(color: Zc.textMuted)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: Zt.label.copyWith(fontSize: 24, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: Zt.caption.copyWith(fontSize: 20),
            filled: true,
            fillColor: Zc.surface,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Dialog(
      backgroundColor: Zc.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Zs.radiusLarge)),
      child: SizedBox(
        width: 880,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: FocusZone(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.storageAddSource, style: Zt.headline),
                const SizedBox(height: 8),
                Text(l.storageFormHint, style: Zt.caption.copyWith(color: Zc.textFaint)),
                const SizedBox(height: 22),
                _field(l.storageNameTitle, _name, hint: l.storageNameHint),
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: SettingChoiceRow<String>(
                    title: l.storageProtocol,
                    value: _protocol,
                    options: _protocols(l),
                    onChanged: (v) => setState(() => _protocol = v),
                  ),
                ),
                _field(l.storageHost, _host, hint: l.storageHostHint),
                Row(children: [
                  Expanded(child: _field(l.storagePort, _port, hint: l.storagePortHint)),
                  const SizedBox(width: 20),
                  Expanded(child: _field(l.storagePath, _path, hint: l.storagePathHint)),
                ]),
                _field(l.storageUserTitle, _user, hint: l.storageUserHint),
                _field(l.storagePasswordTitle, _pass, obscure: true),
                const SizedBox(height: 8),
                Row(children: [
                  TvButton(label: l.save, icon: Icons.check_rounded, primary: true, onSelect: _save),
                  const SizedBox(width: 16),
                  TvButton(label: l.cancel, onSelect: () => Navigator.of(context).pop()),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
