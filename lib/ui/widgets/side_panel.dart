import 'package:flutter/material.dart';

import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import 'net_image.dart';

class PanelOption<T> {
  const PanelOption({required this.value, required this.title, this.subtitle, this.selected = false, this.icon, this.image});

  final T value;
  final String title;
  final String? subtitle;
  final bool selected;
  final IconData? icon;
  final Uri? image;
}

Future<T?> showSidePanel<T>(BuildContext context,
    {required String title, required List<PanelOption<T>> options, ValueChanged<T>? onFocus, String? header}) {
  return Navigator.of(context).push<T>(PageRouteBuilder<T>(
    opaque: false,
    barrierColor: Colors.black54,
    barrierDismissible: true,
    transitionDuration: Zm.normal,
    reverseTransitionDuration: Zm.fast,
    pageBuilder: (_, _, _) => _SidePanel<T>(title: title, options: options, onFocus: onFocus, header: header),
    transitionsBuilder: (_, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0.15, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Zm.curve)),
      child: FadeTransition(opacity: anim, child: child),
    ),
  ));
}

/// Multi-select variant used by the browse page's facet filters.
///
/// Returns the ordered list of selected values when the user confirms, or
/// `null` when they dismiss the panel. An empty list means "clear this facet".
/// Selection is toggled in place; nothing is popped until 确定 so several
/// values in the same dimension can be combined with OR semantics.
Future<List<T>?> showMultiSelectSidePanel<T>(BuildContext context,
    {required String title, required List<PanelOption<T>> options, String confirmLabel = '确定', String clearLabel = '清除'}) {
  return Navigator.of(context).push<List<T>>(PageRouteBuilder<List<T>>(
    opaque: false,
    barrierColor: Colors.black54,
    barrierDismissible: true,
    transitionDuration: Zm.normal,
    reverseTransitionDuration: Zm.fast,
    pageBuilder: (_, _, _) =>
        _MultiSelectPanel<T>(title: title, options: options, confirmLabel: confirmLabel, clearLabel: clearLabel),
    transitionsBuilder: (_, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0.15, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Zm.curve)),
      child: FadeTransition(opacity: anim, child: child),
    ),
  ));
}

class _MultiSelectPanel<T> extends StatefulWidget {
  const _MultiSelectPanel({required this.title, required this.options, required this.confirmLabel, required this.clearLabel});

  final String title;
  final List<PanelOption<T>> options;
  final String confirmLabel;
  final String clearLabel;

  @override
  State<_MultiSelectPanel<T>> createState() => _MultiSelectPanelState<T>();
}

class _MultiSelectPanelState<T> extends State<_MultiSelectPanel<T>> {
  late final List<T> _selected = [
    for (final o in widget.options)
      if (o.selected) o.value,
  ];

  void _toggle(T value) => setState(() {
        if (_selected.contains(value)) {
          _selected.remove(value);
        } else {
          _selected.add(value);
        }
      });

  Widget _footerButton(String label, IconData icon, VoidCallback onTap, {bool focusedOnInit = false}) {
    return TvFocusable(
      autofocus: focusedOnInit,
      onSelect: onTap,
      builder: (context, focused) => AnimatedContainer(
        duration: Zm.fast,
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 30),
        decoration: BoxDecoration(
          color: focused ? Colors.white : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(32),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: focused ? Zc.background : Colors.white, size: 30),
          const SizedBox(width: 10),
          Text(label, style: Zt.label.copyWith(color: focused ? Zc.background : Colors.white, fontSize: 22)),
        ]),
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
          width: 680,
          height: double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 72, 56, 28),
              child: Row(children: [
                Expanded(child: Text(widget.title, style: Zt.headline)),
                Text('${_selected.length}', style: Zt.title.copyWith(color: Zc.accent)),
              ]),
            ),
            Expanded(
              child: FocusZone(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
                  itemCount: widget.options.length,
                  itemBuilder: (context, i) {
                    final o = widget.options[i];
                    final on = _selected.contains(o.value);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TvFocusable(
                        onSelect: () => _toggle(o.value),
                        builder: (context, focused) => AnimatedContainer(
                          duration: Zm.fast,
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                          decoration: BoxDecoration(
                            color: focused ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(children: [
                            Expanded(
                              child: Text(o.title,
                                  style: Zt.label.copyWith(fontSize: 24, color: focused ? Zc.background : Zc.text)),
                            ),
                            Icon(on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                color: focused ? Zc.background : (on ? Zc.accent : Zc.textFaint), size: 30),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 12, 56, 56),
              child: FocusZone(
                child: Row(children: [
                  _footerButton(widget.clearLabel, Icons.clear_all_rounded,
                      () => Navigator.of(context).pop(<T>[])),
                  const SizedBox(width: 20),
                  _footerButton(widget.confirmLabel, Icons.check_circle_rounded,
                      () => Navigator.of(context).pop(List<T>.from(_selected))),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SidePanel<T> extends StatelessWidget {
  const _SidePanel({required this.title, required this.options, this.onFocus, this.header});

  final String title;
  final String? header;
  final List<PanelOption<T>> options;
  final ValueChanged<T>? onFocus;

  @override
  Widget build(BuildContext context) {
    final initial = options.indexWhere((o) => o.selected);
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Zc.surface,
        child: SizedBox(
          width: 680,
          height: double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: EdgeInsets.fromLTRB(56, 72, 56, header == null ? 28 : 10),
              child: Text(title, style: Zt.headline),
            ),
            if (header != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 56, 28),
                child: Row(children: [
                  const Icon(Icons.movie_outlined, color: Zc.textFaint, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(header!,
                        style: Zt.caption.copyWith(fontSize: 20, color: Zc.textMuted), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ),
            Expanded(
              child: FocusZone(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 60),
                  itemCount: options.length,
                  itemBuilder: (context, i) {
                    final o = options[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TvFocusable(
                        autofocus: i == (initial < 0 ? 0 : initial),
                        onSelect: () => Navigator.of(context).pop(o.value),
                        onFocusChange: onFocus == null ? null : (focused) => focused ? onFocus!(o.value) : null,
                        builder: (context, focused) => AnimatedContainer(
                          duration: Zm.fast,
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                          decoration: BoxDecoration(
                            color: focused ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(children: [
                            if (o.icon != null) ...[
                              Icon(o.icon, color: focused ? Zc.background : Zc.textMuted, size: 30),
                              const SizedBox(width: 18),
                            ],
                            if (o.image != null) ...[
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: NetImage(url: o.image, width: 160, height: 90),
                              ),
                              const SizedBox(width: 22),
                            ],
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(o.title, style: Zt.label.copyWith(fontSize: 24, color: focused ? Zc.background : Zc.text)),
                                if (o.subtitle != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(o.subtitle!, style: Zt.caption.copyWith(color: focused ? Colors.black54 : Zc.textFaint)),
                                  ),
                              ]),
                            ),
                            if (o.selected) Icon(Icons.check_rounded, color: focused ? Zc.accent : Zc.accentSoft, size: 30),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
