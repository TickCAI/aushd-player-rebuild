/// Best-effort inference of title / year / season / episode from a media
/// filename. Pure logic: no I/O, no network, no Flutter bindings.
///
/// The smart scraper uses this only to match files the upstream media server
/// never scraped (mounted network drives, freshly imported libraries). Nothing
/// here ever writes back to the upstream source.

final class FileGuess {
  const FileGuess({
    required this.title,
    this.year,
    this.season,
    this.episode,
    required this.isTv,
    required this.confidence,
  });

  final String title;
  final int? year;
  final int? season;
  final int? episode;
  final bool isTv;

  /// 0..1. Higher means the filename carried more reliable structure.
  final double confidence;

  bool get hasEpisode => season != null && episode != null;

  @override
  String toString() =>
      'FileGuess($title, year=$year, S$season E$episode, tv=$isTv, c=${confidence.toStringAsFixed(2)})';
}

final class FilenameGuesser {
  const FilenameGuesser();

  static final _seasonEpisode = <RegExp>[
    RegExp(r'[Ss](\d{1,2})\s*[Ee](\d{1,3})'),
    RegExp(r'\b(\d{1,2})[xX](\d{1,3})\b'),
    RegExp(r'第\s*(\d{1,2})\s*季\s*第\s*(\d{1,3})\s*集'),
  ];
  static final _episodeOnly = RegExp(r'第\s*(\d{1,3})\s*集');
  static final _year = RegExp(r'\b(19\d{2}|20\d{2})\b');

  static final _junk = <RegExp>[
    RegExp(r'\[[^\]]*\]'),
    RegExp(r'\([^)]*\)'),
    RegExp(r'\b(2160p|1080p|720p|480p|4K|UHD|HDR10?|Dolby.?Vision|DV|Atmos)\b', caseSensitive: false),
    RegExp(r'\b(WEB-?DL|WEBRip|WEB|BluRay|BDRip|BRRip|HDTV|DVDRip|DVD|REMUX|CAM|TS|TC)\b', caseSensitive: false),
    RegExp(r'\b(x264|x265|H\.?264|H\.?265|HEVC|XviD|DivX|AVC)\b', caseSensitive: false),
    RegExp(r'\b(AAC|AC3|E-?AC3|DTS|DD5\.1|TrueHD|FLAC|MP3)\b', caseSensitive: false),
    RegExp(r'\b(10bit|8bit|PROPER|REPACK|EXTENDED|UNRATED|IMAX|LIMITED)\b', caseSensitive: false),
    RegExp(r'\b(DIRECTOR.?S.?CUT|THEATRICAL|CINEMA)\b', caseSensitive: false),
  ];

  FileGuess? guess(String filename) {
    var s = filename.trim();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');

    int? season;
    int? episode;
    for (final re in _seasonEpisode) {
      final m = re.firstMatch(s);
      if (m == null) continue;
      final ss = int.tryParse(m.group(1)!);
      final ee = int.tryParse(m.group(2)!);
      if (ss != null && ee != null) {
        season = ss;
        episode = ee;
        s = s.replaceAll(m.group(0)!, ' ');
        break;
      }
    }

    var isTv = season != null && episode != null;
    if (!isTv) {
      final m = _episodeOnly.firstMatch(s);
      if (m != null) {
        final ee = int.tryParse(m.group(1)!);
        if (ee != null) {
          episode = ee;
          isTv = true;
          s = s.replaceAll(m.group(0)!, ' ');
        }
      }
    }

    int? year;
    for (final m in _year.allMatches(s)) {
      final y = int.tryParse(m.group(0)!);
      if (y == null) continue;
      year = y;
      s = s.replaceAll(m.group(0)!, ' ');
    }

    var title = _clean(s);
    if (title.isEmpty && year != null) title = '$year';
    if (title.isEmpty || RegExp(r'^\d+$').hasMatch(title)) return null;

    var confidence = 0.45;
    if (title.length >= 2) confidence += 0.15;
    if (year != null) confidence += 0.20;
    if (isTv) confidence += 0.20;
    if (title.length >= 4) confidence += 0.05;
    if (confidence > 1) confidence = 1;

    return FileGuess(
      title: title,
      year: year,
      season: season,
      episode: episode,
      isTv: isTv,
      confidence: confidence,
    );
  }

  static String _clean(String input) {
    var t = input;
    for (final re in _junk) {
      t = t.replaceAll(re, ' ');
    }
    t = t.replaceAll(RegExp(r'[._]'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    t = t.replaceAll(RegExp(r'^[\s\-\u2013\u2014]+|[\s\-\u2013\u2014]+$'), '');
    return t.trim();
  }
}
