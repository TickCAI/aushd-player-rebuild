import 'package:flutter/material.dart';

import '../../data/discovery_feed.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';

/// Open the full discovery filter panel. Returns the chosen filters, or `null`
/// when the user dismisses the panel without confirming.
///
/// Unlike the old four cycle-chips, this lists every dimension (type / sort /
/// year / region / genre) as a real, detailed list in one place — the "筛选
/// 功能，应该有详细的列表分类" requested for the discovery centre.
Future<DiscoveryFilters?> showDiscoveryFilterPanel(
  BuildContext context, {
  required DiscoveryFilters initial,
  required Map<String, String> labels,
}) {
  return Navigator.of(context).push<DiscoveryFilters>(PageRouteBuilder<DiscoveryFilters>(
    opaque: false,
    barrierColor: Colors.black54,
    barrierDismissible: true,
    transitionDuration: Zm.normal,
    reverseTransitionDuration: Zm.fast,
    pageBuilder: (_, _, _) => _DiscoveryFilterPanel(initial: initial, labels: labels),
    transitionsBuilder: (_, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0.15, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Zm.curve)),
      child: FadeTransition(opacity: anim, child: child),
    ),
  ));
}

class _DiscoveryFilterPanel extends StatefulWidget {
  const _DiscoveryFilterPanel({required this.initial, required this.labels});

  final DiscoveryFilters initial;
  final Map<String, String> labels;

  @override
  State<_DiscoveryFilterPanel> createState() => _DiscoveryFilterPanelState();
}

class _DiscoveryFilterPanelState extends State<_DiscoveryFilterPanel> {
  late FilterMediaType _mediaType;
  late FilterSort _sort;
  int? _yearFrom;
  int? _yearTo;
  int? _genre;
  String? _region;

  @override
  void initState() {
    super.initState();
    final f = widget.initial;
    _mediaType = f.mediaType;
    _sort = f.sort;
    _yearFrom = f.yearFrom;
    _yearTo = f.yearTo;
    _genre = f.genre ?? 0;
    _region = f.region;
  }

  String _l(String key) => widget.labels[key] ?? key;

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 26, bottom: 12),
        child: Text(text, style: Zt.title),
      );

  Widget _option({
    required String label,
    required bool selected,
    required VoidCallback onSelect,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 10, bottom: 10),
      child: TvFocusable(
        onSelect: onSelect,
        builder: (context, focused) => AnimatedContainer(
          duration: Zm.fast,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Zc.request : (focused ? Zc.surface : Zc.background),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected || focused ? Zc.request : Zc.outline),
          ),
          child: Text(
            label,
            style: Zt.label.copyWith(color: selected ? Zc.background : Zc.text),
          ),
        ),
      ),
    );
  }

  Widget _footerButton(String label, VoidCallback onSelect, {bool primary = false}) {
    return TvFocusable(
      onSelect: onSelect,
      builder: (context, focused) => AnimatedContainer(
        duration: Zm.fast,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        decoration: BoxDecoration(
          color: primary ? Zc.request : (focused ? Zc.surface : Zc.background),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: focused || primary ? Zc.request : Zc.outline),
        ),
        child: Text(
          label,
          style: Zt.label.copyWith(color: primary ? Zc.background : Zc.text),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Zc.surface,
        child: SizedBox(
          width: 760,
          height: double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 64, 48, 8),
              child: Text(_l('FilterTitle'), style: Zt.headline),
            ),
            Expanded(
              child: FocusZone(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(48, 12, 48, 32),
                  children: [
                    _sectionTitle(_l('MediaType')),
                    Wrap(children: [
                      for (final v in FilterMediaType.values)
                        _option(
                          label: _l(switch (v) {
                            FilterMediaType.all => 'FilterAll',
                            FilterMediaType.movie => 'FilterMovie',
                            FilterMediaType.tv => 'FilterTv',
                          }),
                          selected: _mediaType == v,
                          onSelect: () => setState(() => _mediaType = v),
                        ),
                    ]),
                    _sectionTitle(_l('Sort')),
                    Wrap(children: [
                      for (final v in FilterSort.values)
                        _option(
                          label: _l(switch (v) {
                            FilterSort.hot => 'SortHot',
                            FilterSort.rating => 'SortRating',
                            FilterSort.latest => 'SortLatest',
                          }),
                          selected: _sort == v,
                          onSelect: () => setState(() => _sort = v),
                        ),
                    ]),
                    _sectionTitle(_l('Year')),
                    Wrap(children: [
                      for (final o in DiscoveryFilters.yearOptions)
                        _option(
                          label: _l(o.$3),
                          selected: _yearFrom == o.$1 && _yearTo == o.$2,
                          onSelect: () => setState(() {
                            _yearFrom = o.$1;
                            _yearTo = o.$2;
                          }),
                        ),
                    ]),
                    _sectionTitle(_l('Region')),
                    Wrap(children: [
                      for (final o in DiscoveryFilters.regionOptions)
                        _option(
                          label: _l(o.$2),
                          selected: (_region ?? '') == (o.$1 ?? ''),
                          onSelect: () => setState(() => _region = o.$1),
                        ),
                    ]),
                    _sectionTitle(_l('Genre')),
                    Wrap(children: [
                      for (final o in DiscoveryFilters.genreOptions)
                        _option(
                          label: _l(o.$2),
                          selected: (_genre ?? 0) == o.$1,
                          onSelect: () => setState(() => _genre = o.$1),
                        ),
                    ]),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 8, 48, 48),
              child: Row(children: [
                _footerButton(_l('Clear'), () => setState(() {
                  _mediaType = FilterMediaType.all;
                  _sort = FilterSort.hot;
                  _yearFrom = null;
                  _yearTo = null;
                  _genre = 0;
                  _region = null;
                })),
                const SizedBox(width: 16),
                _footerButton(
                  _l('Confirm'),
                  () => Navigator.of(context).pop(DiscoveryFilters(
                    mediaType: _mediaType,
                    sort: _sort,
                    yearFrom: _yearFrom,
                    yearTo: _yearTo,
                    genre: _genre,
                    region: _region,
                  )),
                  primary: true,
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
