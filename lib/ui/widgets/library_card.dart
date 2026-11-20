import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../data/catalog_api.dart';
import '../../l10n/l10n.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'net_image.dart';

/// Library tiles match the 380x214 "continue watching" landscape card so the
/// two shelves read as one grid instead of the libraries towering over
/// everything below them. Artwork is cropped (`BoxFit.cover`) for real
/// backdrops/stills; only Emby's auto-generated vertical poster collage falls
/// back to `BoxFit.contain` so its titles are never sliced off.
const double libraryCardWidth = Zs.landscapeWidth;

/// A landscape tile for a real Emby/Jellyfin library (a `CollectionFolder`).
///
/// Artwork comes straight from the server: a real backdrop from an item inside
/// the library is preferred, because `ImageTags.Primary` is usually an
/// auto-generated tall collage of movie posters. Real stills fill the tile;
/// the vertical collage alone is letterboxed over a blurred copy of itself.
/// Title is one line plus a `type · count` meta line — the old logo and
/// two-line overview made a 380-wide card unreadable.
class LibraryCard extends StatelessWidget {
  const LibraryCard({
    super.key,
    required this.view,
    this.width = libraryCardWidth,
    this.autofocus = false,
    this.onFocus,
    this.onSelect,
  });

  final LibraryView view;
  final double width;
  final bool autofocus;
  final VoidCallback? onFocus;
  final VoidCallback? onSelect;

  static String typeLabel(String? type, L10n l10n) {
    final zh = ContentZh.enabled;
    return switch (type) {
      'movies' || 'boxsets' => l10n.movies,
      'tvshows' => l10n.shows,
      'music' => zh ? '音乐' : 'Music',
      'photos' || 'homevideos' => zh ? '相册' : 'Photos',
      'books' => zh ? '图书' : 'Books',
      'livetv' => zh ? '直播电视' : 'Live TV',
      'mixed' => zh ? '混合内容' : 'Mixed',
      'playlists' => zh ? '播放列表' : 'Playlists',
      _ => zh ? '媒体库' : 'Library',
    };
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppServicesScope.read(context).catalog;
    final l10n = context.l10n;
    final height = width * 9 / 16;
    final cover = catalog.libraryArtwork(view, width: (width * 1.6).round());
    // Emby's generated Primary/Thumb is a tall poster collage; cropping that
    // into 16:9 cuts off every title. Real backdrops/stills must fill instead.
    final isCollage = cover != null && CatalogApi.libraryArtworkIsCollage(view);
    final count = view.itemCount;
    final titleText = Text(view.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.title);

    return TvFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      onFocusChange: (focused) {
        if (focused) onFocus?.call();
      },
      builder: (context, focused) => FocusFrame(
        focused: focused,
        scale: 1.04,
        radius: Zs.radiusLarge,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(fit: StackFit.expand, children: [
            if (cover != null && isCollage) ...[
              // Only the generated vertical collage needs a blurred underlay
              // to fill the letterbox. Real stills fill the tile directly.
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: NetImage(url: cover, width: width, height: height, fit: BoxFit.cover),
              ),
              const DecoratedBox(decoration: BoxDecoration(color: Color(0x59000000))),
            ],
            NetImage(
              url: cover,
              width: width,
              height: height,
              fit: isCollage ? BoxFit.contain : BoxFit.cover,
              fallback: TitleArt(title: view.name, icon: Icons.video_library_outlined),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xF0000000), Color(0x99000000), Color(0x00000000)],
                  stops: [0.0, 0.45, 0.85],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  titleText,
                  const SizedBox(height: 4),
                  MetaLine(
                    [typeLabel(view.collectionType, l10n), if (count != null && count > 0) l10n.filmCount(count)],
                    style: Zt.caption.copyWith(color: Zc.textMuted),
                  ),
                ],
              ),
            ),
            if (focused)
              Positioned(
                top: 12,
                right: 12,
                child: Pill(ContentZh.enabled ? '进入' : 'Open', icon: Icons.arrow_forward_rounded, color: Zc.accent),
              ),
          ]),
        ),
      ),
    );
  }
}
