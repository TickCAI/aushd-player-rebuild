import 'dart:convert';

/// One danmaku (bullet-comment) line.
///
/// Times are milliseconds from the start of the media. `mode` is the display
/// channel: `scroll` (right-to-left, the default), `top` or `bottom` (a static
/// line centred on that edge). `color` is 0xRRGGBB, null = white.
final class Danmaku {
  const Danmaku({
    required this.timeMs,
    required this.text,
    this.mode = DanmakuMode.scroll,
    this.color,
    this.fontSize,
  });

  final int timeMs;
  final String text;
  final DanmakuMode mode;
  final int? color;
  final int? fontSize;
}

enum DanmakuMode { scroll, top, bottom }

/// Parsers for the two wire formats the app understands.
///
/// Both are tolerant: unknown fields are ignored and malformed lines are
/// skipped rather than throwing, because a single bad entry must never blank
/// the whole overlay.
abstract final class DanmakuCodec {
  /// Bilibili XML: `<d p="time,mode,fontsize,color,...">text</d>`.
  /// mode 1/2/8 -> scroll, 4 -> bottom, 5 -> top, 6 -> scroll, 7 -> scroll.
  static List<Danmaku> parseBilibiliXml(String body) {
    final out = <Danmaku>[];
    final re = RegExp(r'<d\s+p="([^"]*)"[^>]*>(.*?)</d>', dotAll: true);
    for (final m in re.allMatches(body)) {
      final attrs = (m.group(1) ?? '').split(',');
      final text = _xmlUnescape((m.group(2) ?? '')).trim();
      if (text.isEmpty || attrs.length < 4) continue;
      final seconds = double.tryParse(attrs[0]);
      if (seconds == null) continue;
      final rawMode = int.tryParse(attrs[1]) ?? 1;
      final size = int.tryParse(attrs[2]);
      final color = int.tryParse(attrs[3]);
      out.add(Danmaku(
        timeMs: (seconds * 1000).round(),
        text: text,
        mode: switch (rawMode) {
          4 => DanmakuMode.bottom,
          5 => DanmakuMode.top,
          _ => DanmakuMode.scroll,
        },
        fontSize: size,
        color: color,
      ));
    }
    out.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return out;
  }

  /// The AusHD shared-danmaku JSON contract:
  /// `{items:[{timeMs,text,color,mode,size}]}` (mode: scroll|top|bottom).
  static List<Danmaku> parseJson(String body) {
    final decoded = jsonDecode(body);
    final raw = decoded is Map ? decoded['items'] : decoded;
    if (raw is! List) return const [];
    final out = <Danmaku>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final text = '${e['text'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      final timeMs = (e['timeMs'] as num?)?.toInt() ?? ((e['time'] as num?)?.toInt() ?? 0);
      final mode = switch ('${e['mode'] ?? 'scroll'}') {
        'top' => DanmakuMode.top,
        'bottom' => DanmakuMode.bottom,
        _ => DanmakuMode.scroll,
      };
      final color = e['color'];
      out.add(Danmaku(
        timeMs: timeMs,
        text: text,
        mode: mode,
        color: color is num ? color.toInt() : null,
        fontSize: (e['size'] as num?)?.toInt(),
      ));
    }
    out.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return out;
  }

  /// Dispatch on the payload shape so a provider can hand back either format.
  static List<Danmaku> parseAuto(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('<')) return parseBilibiliXml(body);
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return parseJson(body);
    return const [];
  }

  static String _xmlUnescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}
