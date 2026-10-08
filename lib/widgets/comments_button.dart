import 'package:flutter/material.dart';

import '../models/models.dart';
import '../pages/comments_page.dart';
import '../services/sources.dart';

class CommentsButton extends StatelessWidget {
  final MediaItem item;
  final MediaEpisode? episode;
  final Color? color;
  final bool showLabel;

  const CommentsButton({
    super.key,
    required this.item,
    this.episode,
    this.color,
    this.showLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    final scope = Sources.commentScope(item);
    if (scope == null || (scope == CommentScope.chapter && episode == null)) {
      return const SizedBox.shrink();
    }
    void open() => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            CommentsPage(item: item, episode: episode, scope: scope),
      ),
    );
    if (showLabel) {
      return TextButton.icon(
        onPressed: open,
        icon: const Icon(Icons.chat_bubble_outline),
        label: Text(scope.label),
      );
    }
    return IconButton(
      tooltip: scope.label,
      icon: Icon(Icons.chat_bubble_outline, color: color),
      onPressed: open,
    );
  }
}
