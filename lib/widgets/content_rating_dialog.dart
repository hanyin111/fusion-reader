import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/content_filter.dart';
import '../services/storage.dart';

/// Returns true only when the caller should open its removal confirmation.
Future<bool> showContentRatingActions(
  BuildContext context,
  MediaItem item,
) async {
  final current = Storage.classifyItem(item);
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(item.title),
              subtitle: Text(
                '内容分级 · 当前为 ${ContentFilter.isNsfw(item) ? 'NSFW' : 'SFW'}',
              ),
            ),
            for (final rating in ContentRating.values)
              ListTile(
                leading: Icon(
                  current.contentRating == rating
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(switch (rating) {
                  ContentRating.source => '跟随插件设置',
                  ContentRating.sfw => '单独设为 SFW',
                  ContentRating.nsfw => '单独设为 NSFW',
                }),
                subtitle: rating == ContentRating.source
                    ? const Text('本地导入的内容默认视为 SFW')
                    : null,
                onTap: () => Navigator.pop(context, rating.name),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('从书架移除'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    ),
  );
  if (action == 'remove') return true;
  if (action != null) {
    await Storage.setContentRating(item, ContentRating.values.byName(action));
  }
  return false;
}
