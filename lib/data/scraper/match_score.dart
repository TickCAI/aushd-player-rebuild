/// Similarity scoring between a guessed filename and a TMDB search candidate.
/// Pure logic, deterministic, no I/O.
///
/// The scraper uses a confidence gate so that a missing poster stays missing
/// rather than showing a *wrong* poster. See [verdict].

final class MatchScore {
  const MatchScore(this.score, this.reason);

  final double score;
  final String reason;

  @override
  String toString() => 'MatchScore(${score.toStringAsFixed(2)}, $reason)';
}

final class MatchVerdict {
  const MatchVerdict._(this.accept, this.label);

  final bool accept;
  final String label;

  static const auto = MatchVerdict._(true, 'auto');
  static const review = MatchVerdict._(true, 'review');
  static const skip = MatchVerdict._(false, 'skip');
}

final class MatchScorer {
  const MatchScorer();

  /// High-confidence sources (an explicit upstream tmdbId) bypass scoring.
  static const autoThreshold = 0.78;
  static const reviewThreshold = 0.55;

  /// Score a single candidate. [candidateTitle]/[candidateOriginal] may be in
  /// any language; [candidateYear] may be null when TMDB did not supply one.
  MatchScore score({
    required String queryTitle,
    required String candidateTitle,
    String? candidateOriginal,
    int? queryYear,
    int? candidateYear,
    bool queryIsTv = false,
    bool candidateIsTv = false,
  }) {
    final best = <String>[candidateTitle, if (candidateOriginal != null) candidateOriginal]
        .map(_normalize)
        .where((s) => s.isNotEmpty)
        .toList();
    final q = _normalize(queryTitle);
    if (q.isEmpty || best.isEmpty) return const MatchScore(0, 'empty');

    var text = 0.0;
    for (final c in best) {
      final v = _similarity(q, c);
      if (v > text) text = v;
    }

    var score = text * 0.75;
    final reason = <String>['text=${text.toStringAsFixed(2)}'];

    if (queryYear != null && candidateYear != null) {
      if (queryYear == candidateYear) {
        score += 0.20;
        reason.add('year+');
      } else if ((queryYear - candidateYear).abs() == 1) {
        score += 0.06;
        reason.add('year~1');
      } else {
        score -= 0.15;
        reason.add('year-');
      }
    }

    if (queryIsTv == candidateIsTv) {
      score += 0.05;
      reason.add('type+');
    } else {
      score -= 0.10;
      reason.add('type-');
    }

    if (score > 1) score = 1;
    if (score < 0) score = 0;
    return MatchScore(score, reason.join(','));
  }

  MatchVerdict verdict(MatchScore score, {double? secondBest}) {
    if (score.score >= autoThreshold) return MatchVerdict.auto;
    if (score.score < reviewThreshold) return MatchVerdict.skip;
    // A clear winner over the runner-up is safe to apply automatically.
    if (secondBest != null && score.score - secondBest >= 0.12) return MatchVerdict.auto;
    return MatchVerdict.review;
  }

  static String _normalize(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// Token-set Dice coefficient with a containment bonus. Robust to word order
  /// and to quality tags leaking into the guess.
  static double _similarity(String a, String b) {
    if (a == b) return 1;
    final as = a.split(' ').where((x) => x.isNotEmpty).toSet();
    final bs = b.split(' ').where((x) => x.isNotEmpty).toSet();
    if (as.isEmpty || bs.isEmpty) return 0;
    final inter = as.intersection(bs).length;
    final dice = 2 * inter / (as.length + bs.length);
    final containment = inter / (as.length < bs.length ? as.length : bs.length);
    return (dice + containment) / 2;
  }
}
