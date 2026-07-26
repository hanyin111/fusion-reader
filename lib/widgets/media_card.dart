import 'package:flutter/material.dart';

import '../models/models.dart';
import '../pages/detail_page.dart';
import '../services/sources.dart';
import 'source_image.dart';

Color typeColor(MediaType type) {
  switch (type) {
    case MediaType.manga:
      return Colors.blue;
    case MediaType.novel:
      return Colors.green;
    case MediaType.anime:
      return Colors.deepPurple;
  }
}

class MediaCard extends StatelessWidget {
  final MediaItem item;
  final bool showTypeBadge;
  final String? subtitle;
  final VoidCallback? onLongPress;

  const MediaCard({
    super.key,
    required this.item,
    this.showTypeBadge = true,
    this.subtitle,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final sourceName = Sources.displayName(item.package);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailPage(item: item)),
      ),
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SourceImage(
                    url: item.cover,
                    package: item.package,
                    fit: BoxFit.cover,
                    error: Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.image_not_supported_outlined),
                    ),
                  ),
                ),
                if (showTypeBadge)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: typeColor(item.type).withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        item.type.label,
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                    ),
                    child: Text(
                      sourceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
        ],
      ),
    );
  }
}
