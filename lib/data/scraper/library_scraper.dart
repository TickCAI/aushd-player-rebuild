/// One-shot "complete my library" scan.
///
/// The visibility prefetch in [SmartScraper] only fills what the user scrolls
/// past. This class walks the whole library once, on explicit request, so a
/// fresh import can be straightened out without scrolling through everything.
///
/// It obeys the same rules as the prefetch: zero write-back, local cache only,
/// and nothing is applied unless the match clears the auto threshold.
library;

import 'package:flutter/foundation.dart';

import '../../core/emby/models/emby_item.dart';
import '../catalog_api.dart';
import 'smart_scraper.dart';

/// Immutable progress snapshot for the settings UI.
@immutable
final class LibraryScrapeProgress {
  const LibraryScrapeProgress({
    this.total = 0,
    this.done = 0,
    this.applied = 0,
    this.failed = 0,
    this.running = false,
    this.finished = false,
    this.cancelled = false,
  });

  static const idle = LibraryScrapeProgress();

  final int total;
  final int done;
  final int applied;
  final int failed;
  final bool running;
  final bool finished;
  final bool cancelled;

  /// 0..1, safe when [total] is 0.
  double get fraction => total == 0 ? 0 : (done / total).clamp(0, 1);

  LibraryScrapeProgress copyWith({
    int? total,
    int? done,
    int? applied,
    int? failed,
    bool? running,
    bool? finished,
    bool? cancelled,
  }) =>
      LibraryScrapeProgress(
        total: total ?? this.total,
        done: done ?? this.done,
        applied: applied ?? this.applied,
        failed: failed ?? this.failed,
        running: running ?? this.running,
        finished: finished ?? this.finished,
        cancelled: cancelled ?? this.cancelled,
      );
}

/// Scans the whole library once and scrapes every item that has no artwork.
///
/// Only one scan runs at a time; starting a second one while [running] is true
/// is a no-op so a double press on the remote cannot fork two scans.
final class LibraryScraper {
  LibraryScraper({required CatalogApi catalog, required SmartScraper? scraper})
      : _catalog = catalog,
        scraper = scraper;

  final CatalogApi _catalog;

  /// The scraper this scan borrows its network and cache from. Exposed so a
  /// caller can tell whether a stored progress bar still belongs to the current
  /// settings (a new TMDB key builds a new SmartScraper).
  final SmartScraper? scraper;

  final ValueNotifier<LibraryScrapeProgress> progress =
      ValueNotifier<LibraryScrapeProgress>(LibraryScrapeProgress.idle);

  bool _cancel = false;

  /// Upper bound on library size for one scan. Anything beyond this is left to
  /// the visibility prefetch; a single button press should not spin for hours.
  static const _maxItems = 5000;
  static const _pageSize = 200;

  bool get running => progress.value.running;

  void cancel() => _cancel = true;

  /// Runs the scan. Returns the final snapshot; never throws.
  Future<LibraryScrapeProgress> run() async {
    final worker = scraper;
    if (worker == null || !worker.available) return progress.value;
    if (running) return progress.value;

    _cancel = false;
    progress.value = const LibraryScrapeProgress(running: true);

    try {
      await worker.ready;
      final targets = await _collect(worker);
      if (_cancel) return _finish(cancelled: true);
      if (targets.isEmpty) return _finish();

      progress.value = progress.value.copyWith(total: targets.length);
      for (final item in targets) {
        if (_cancel) return _finish(cancelled: true);
        final current = progress.value;
        try {
          final result = await worker.scrape(item);
          progress.value = current.copyWith(
            done: current.done + 1,
            applied: current.applied + (result.applied ? 1 : 0),
          );
        } catch (e) {
          debugPrint('[scraper] library scan item ${item.id}: $e');
          progress.value = current.copyWith(done: current.done + 1, failed: current.failed + 1);
        }
      }
      return _finish();
    } catch (e) {
      debugPrint('[scraper] library scan failed: $e');
      return _finish();
    }
  }

  /// Pages through Movie + Series and keeps only items the scraper can help.
  Future<List<EmbyItem>> _collect(SmartScraper worker) async {
    final out = <EmbyItem>[];
    var start = 0;
    while (start < _maxItems && !_cancel) {
      final page = await _catalog.query(
        types: const ['Movie', 'Series'],
        recursive: true,
        start: start,
        limit: _pageSize,
        localize: false,
      );
      if (page.items.isEmpty) break;
      for (final item in page.items) {
        if (worker.needsScrape(item)) out.add(item);
      }
      start += page.items.length;
      if (start >= page.total) break;
      // Surface how many candidates have been found so a huge library does not
      // look frozen while it is still only counting.
      progress.value = progress.value.copyWith(total: out.length);
    }
    return out;
  }

  LibraryScrapeProgress _finish({bool cancelled = false}) {
    final next = progress.value.copyWith(
      running: false,
      finished: true,
      cancelled: cancelled,
    );
    progress.value = next;
    return next;
  }

  void dispose() => progress.dispose();
}
