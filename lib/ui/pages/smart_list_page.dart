import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/emby/models/emby_item.dart';
import '../../data/smart_list.dart';
import '../../data/taste_profile.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import 'routes.dart';

/// Full-grid destination behind a smart shelf's "More" button. Resolves the
/// same declarative spec the home row uses, so the grid always matches the
/// shelf (§5.1) instead of being a second, subtly different query.
class SmartListPage extends StatefulWidget {
  const SmartListPage({super.key, required this.spec});

  final SmartSpec spec;

  @override
  State<SmartListPage> createState() => _SmartListPageState();
}

class _SmartListPageState extends State<SmartListPage> {
  final _grid = RevealController(margin: 120);
  List<EmbyItem>? _items;
  AppServices? _services;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services == null) {
      _services = AppServicesScope.read(context);
      _services!.libraryChanged.addListener(_reload);
      _reload();
    }
  }

  @override
  void dispose() {
    _services?.libraryChanged.removeListener(_reload);
    _grid.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final s = _services!;
    try {
      final taste = await TasteProfile.load(s.catalog);
      final items = await SmartListResolver(s.catalog, taste).resolve(widget.spec);
      if (mounted) setState(() => _items = items);
    } catch (e) {
      debugPrint('[smart list ${widget.spec.id}] $e');
      if (mounted) setState(() => _items ??= const []);
    }
  }

  String _title(L10n l10n) => switch (widget.spec.id) {
        'this-week' => l10n.smartThisWeek,
        'classics' => l10n.smartClassics,
        'fresh' => l10n.smartFresh,
        'gems' => l10n.smartGems,
        'one-ep' => l10n.smartOneEp,
        'picks' => l10n.smartPicks,
        'my-list' => l10n.myList,
        _ => widget.spec.id,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _items;
    final columns = AppServicesScope.of(context).settings.posterSize.columns;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: contentLeft, top: 70, right: 120, bottom: 26),
        child: Row(children: [
          Text(_title(l10n), style: Zt.headline),
          const SizedBox(width: 18),
          if (items != null && items.isNotEmpty)
            Text('${items.length}', style: Zt.title.copyWith(color: Zc.textFaint)),
        ]),
      ),
      Expanded(
        child: items != null && items.isEmpty
            ? Padding(
                padding: const EdgeInsets.only(left: contentLeft, top: 40, right: 120),
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900), child: Text(l10n.myListEmpty, style: Zt.body)),
              )
            : LayoutBuilder(builder: (context, box) {
                final cardW = posterGridCardWidth(box.maxWidth, columns);
                return FocusZone(
                  debugLabel: 'smart-${widget.spec.id}-grid',
                  child: GridView.builder(
                    controller: _grid,
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.fromLTRB(contentLeft, 16, 120, 140),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 26,
                      crossAxisSpacing: Zs.cardGap,
                      childAspectRatio: cardW / (cardW * 1.5 + 70),
                    ),
                    itemCount: items?.length ?? 8,
                    itemBuilder: (context, i) {
                      if (items == null) return SkeletonBox(width: cardW, height: cardW * 1.5);
                      final item = items[i];
                      return Align(
                        alignment: Alignment.topLeft,
                        child: LayoutBuilder(
                          builder: (context, box) => PosterCard(
                            item: item,
                            width: box.maxWidth,
                            onSelect: () => openItem(context, item),
                          ),
                        ),
                      );
                    },
                  ),
                );
              }),
      ),
    ]);
  }
}
