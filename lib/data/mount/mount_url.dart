/// Pure helpers for turning the unified storage-source form fields
/// (protocol / host / port / path) into a [baseUrl] and back.
///
/// Kept free of Flutter/UI imports so it can be unit-tested on the CI
/// host without a widget binding.

({String protocol, String host, String port, String path}) parseMountUrl(String url) {
  final raw = url.trim();
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) {
    // A bare host (e.g. "list.example.com") or an old free-form value.
    return (protocol: 'http', host: raw, port: '', path: '');
  }
  final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme.toLowerCase();
  return (
    protocol: scheme,
    host: uri.host,
    port: uri.port > 0 ? uri.port.toString() : '',
    path: uri.path == '/' ? '' : uri.path,
  );
}

String buildMountUrl({
  required String protocol,
  required String host,
  String port = '',
  String path = '',
}) {
  var h = host.trim();
  var p = port.trim();
  // Tolerate a user pasting a full URL into the host field.
  final pasted = Uri.tryParse(h);
  if (pasted != null && pasted.scheme.isNotEmpty && pasted.host.isNotEmpty) {
    h = pasted.host;
    if (p.isEmpty && pasted.port > 0) p = pasted.port.toString();
  }
  h = h.replaceFirst(RegExp(r'^//'), '').replaceFirst(RegExp(r'/+$'), '');
  final authority = p.isEmpty ? h : '$h:$p';
  final tail = path.trim();
  final cleanPath = tail.isEmpty || tail == '/' ? '' : (tail.startsWith('/') ? tail : '/$tail');
  return '$protocol://$authority$cleanPath';
}

/// Default port shown in the form for a given protocol (empty = omit).
String defaultPortFor(String protocol) => switch (protocol) {
      'https' => '443',
      'ftp' => '21',
      _ => '80',
    };
