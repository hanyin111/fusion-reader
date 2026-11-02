import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/models.dart';
import 'storage.dart';

/// A display preference, never a destructive library or export filter.
class ContentFilter {
  static bool get showNsfw =>
      Storage.setting('showNsfw', defaultValue: false) == true;
  static Future<void> setShowNsfw(bool value) =>
      Storage.setSetting('showNsfw', value);
  static Listenable get changes => Listenable.merge([
    Storage.settingsBox.listenable(keys: ['showNsfw']),
    Storage.extensionsBox.listenable(),
    Storage.favoritesBox.listenable(),
    Storage.historyBox.listenable(),
  ]);

  static bool allowsSource(bool nsfw) => showNsfw || !nsfw;
  static bool isNsfw(MediaItem item) {
    final resolved = Storage.classifyItem(item);
    return switch (resolved.contentRating) {
      ContentRating.nsfw => true,
      ContentRating.sfw => false,
      ContentRating.source => resolved.sourceNsfw ?? false,
    };
  }

  static bool allowsItem(MediaItem item) => showNsfw || !isNsfw(item);
}
