import 'dart:io';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/video_item.dart';

/// A single history / favorites row: poster thumbnail, title, URL and the
/// captured metadata (source, duration, resolution).
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
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPlay,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(item: item),
              const SizedBox(width: 12),
              Expanded(child: _Details(item: item)),
              Column(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onToggleFavorite,
                    icon: Icon(
                      item.favorite ? Icons.favorite : Icons.favorite_border,
                      color: item.favorite ? AppTheme.primaryRed : Colors.grey,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, color: Colors.grey),
                  ),
                ],
              ),
            ],
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
            const Center(
              child: Icon(Icons.play_circle_fill,
                  color: Colors.white70, size: 26),
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
        child: Icon(
          item.mode == PlayerMode.web
              ? Icons.public
              : Icons.movie_creation_outlined,
          color: Colors.white38,
          size: 28,
        ),
      );
}

class _Details extends StatelessWidget {
  final VideoItem item;
  const _Details({required this.item});

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      item.source,
      ?item.resolutionLabel,
    ].join('  •  ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title.isEmpty ? 'Untitled video' : item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontWeight: FontWeight.w600, fontSize: 15, color: Colors.black87),
        ),
        const SizedBox(height: 3),
        Text(
          item.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.black45),
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
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
