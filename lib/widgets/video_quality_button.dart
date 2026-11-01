import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/video_quality.dart';

class VideoQualitySelection {
  final List<VideoQuality> options;
  final int selected;
  final bool busy;

  const VideoQualitySelection({
    this.options = const [],
    this.selected = 0,
    this.busy = false,
  });
}

/// A listenable also updates controls hosted in the separate fullscreen route.
class VideoQualityButton extends StatelessWidget {
  final ValueListenable<VideoQualitySelection> selection;
  final ValueChanged<VideoQuality> onSelected;
  final Color? color;

  const VideoQualityButton({
    super.key,
    required this.selection,
    required this.onSelected,
    this.color,
  });

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<VideoQualitySelection>(
        valueListenable: selection,
        builder: (context, value, _) => PopupMenuButton<int>(
          tooltip: '清晰度',
          enabled: !value.busy && value.options.isNotEmpty,
          initialValue: value.selected,
          itemBuilder: (context) => [
            for (var i = 0; i < value.options.length; i++)
              PopupMenuItem(
                value: i,
                onTap: () => onSelected(value.options[i]),
                child: Row(
                  children: [
                    Icon(i == value.selected ? Icons.check : null, size: 16),
                    const SizedBox(width: 8),
                    Flexible(child: Text(value.options[i].label, maxLines: 2)),
                  ],
                ),
              ),
            if (value.options.length == 1)
              const PopupMenuItem(enabled: false, child: Text('当前视频仅提供一种清晰度')),
          ],
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 56,
              maxWidth: 120,
              minHeight: 48,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: value.busy
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                        ),
                      )
                    : Text(
                        value.options.isEmpty
                            ? '清晰度'
                            : value.options[value.selected].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: color, fontSize: 14),
                      ),
              ),
            ),
          ),
        ),
      );
}
