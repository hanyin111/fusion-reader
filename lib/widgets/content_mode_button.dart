import 'package:flutter/material.dart';
import '../services/content_filter.dart';

class ContentModeButton extends StatelessWidget {
  const ContentModeButton({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ContentFilter.changes,
    builder: (context, _) => TextButton(
      onPressed: () => ContentFilter.setShowNsfw(!ContentFilter.showNsfw),
      child: Tooltip(
        message: ContentFilter.showNsfw
            ? '显示全部内容，点击切换到 SFW'
            : '仅显示 SFW，点击显示全部内容',
        child: Text(ContentFilter.showNsfw ? 'NSFW' : 'SFW'),
      ),
    ),
  );
}
