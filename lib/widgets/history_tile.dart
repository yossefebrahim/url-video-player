import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app_theme.dart';
import '../models/video_item.dart';

/// A single history / favorites row: poster thumbnail, title, URL and the
/// captured metadata (source, resolution, relative time).
///
/// Tap = play · swipe left = delete (parent shows an Undo snackbar) · trailing
/// heart toggles favorite. Delete + favorite are also exposed as custom
/// semantics actions so screen-reader users aren't limited to the swipe.
class HistoryTile extends StatelessWidget {
  final VideoItem item;
  final VoidCallback onPlay;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;

  const HistoryTile({
    super.key,
    required this.item,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(item.url),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.error,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        child: Icon(Icons.delete_outline, color: scheme.onError),
      ),
      child: Semantics(
        button: true,
        label: 'Play ${item.title.isEmpty ? 'video' : item.title}',
        customSemanticsActions: {
          CustomSemanticsAction(
            label: item.favorite ? 'Remove from favorites' : 'Add to favorites',
          ): onToggleFavorite,
          const CustomSemanticsAction(label: 'Delete'): onDelete,
        },
        child: Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(AppTheme.rMd),
            onTap: onPlay,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Thumbnail(item: item),
                  const SizedBox(width: 12),
                  Expanded(child: _Details(item: item)),
                  IconButton(
                    onPressed: onToggleFavorite,
                    tooltip: item.favorite
                        ? 'Remove from favorites'
                        : 'Add to favorites',
                    icon: Icon(
                      item.favorite ? Icons.favorite : Icons.favorite_border,
                      color: item.favorite
                          ? AppTheme.primaryRed
                          : scheme.onSurfaceVariant,
                      semanticLabel: item.favorite ? 'Favorited' : 'Not favorited',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final VideoItem item;
  const _Thumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    // Avoid synchronous disk I/O (existsSync) in build; the stored path is only
    // set once a thumbnail was written, and Image.file's errorBuilder covers the
    // rare case where the cached file was cleared out from under us.
    final path = item.thumbnailPath;
    final duration = item.durationLabel;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 104,
        height: 64,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (path != null)
              Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(),
              )
            else
              _placeholder(),
            const ExcludeSemantics(
              child: Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 26),
              ),
            ),
            if (duration != null)
              Positioned(
                right: 3,
                bottom: 3,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  color: Colors.black.withValues(alpha: 0.7),
                  child: Text(
                    duration,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
        color: Colors.black87,
        child: ExcludeSemantics(
          child: Icon(
            item.mode == PlayerMode.web
                ? Icons.public
                : Icons.movie_creation_outlined,
            color: Colors.white54,
            size: 28,
          ),
        ),
      );
}

class _Details extends StatelessWidget {
  final VideoItem item;
  const _Details({required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final rel = _relativeTime(item.addedAt);
    final meta = <String>[
      item.source,
      ?item.resolutionLabel,
      if (rel.isNotEmpty) rel,
    ].join('  •  ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title.isEmpty ? 'Untitled video' : item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          item.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Icon(
              item.mode == PlayerMode.web
                  ? Icons.public
                  : Icons.play_arrow_rounded,
              size: 14,
              color: AppTheme.primaryRed,
            ),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Compact relative time from an epoch-millis timestamp ("2h ago").
  static String _relativeTime(int epochMs) {
    if (epochMs <= 0) return '';
    final diff =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
    return '${(diff.inDays / 365).floor()}y ago';
  }
}
