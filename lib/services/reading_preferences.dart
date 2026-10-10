import 'package:flutter/foundation.dart';

import '../models/reader_settings.dart';
import 'storage.dart';

/// Portable reader preferences only. Never copy the general settings box,
/// which may also contain account or extension state.
class ReadingPreferences {
  static String get platform => defaultTargetPlatform.name.toLowerCase();
  static const platforms = {
    'android',
    'ios',
    'windows',
    'macos',
    'linux',
    'fuchsia',
  };
  static const ranges = {
    'novel_fontSize': (12.0, 40.0),
    'novel_lineHeight': (1.0, 2.6),
    'novel_paragraphSpacing': (0.0, 40.0),
    'novel_horizontalPadding': (0.0, 80.0),
    'novel_verticalPadding': (0.0, 80.0),
    'novel_letterSpacing': (0.0, 6.0),
  };
  static const booleans = {
    'novel_indentFirstLine',
    'novel_justify',
    'novel_paged',
    'mangaWebtoon',
  };

  static Map<String, Object> capture() {
    final s = NovelReaderSettings.load();
    return {
      'novel_fontSize': s.fontSize,
      'novel_lineHeight': s.lineHeight,
      'novel_paragraphSpacing': s.paragraphSpacing,
      'novel_horizontalPadding': s.horizontalPadding,
      'novel_verticalPadding': s.verticalPadding,
      'novel_letterSpacing': s.letterSpacing,
      'novel_fontWeightIndex': s.fontWeightIndex,
      'novel_indentFirstLine': s.indentFirstLine,
      'novel_justify': s.justify,
      'novel_paged': s.paged,
      'novel_fontName': s.fontName,
      'novel_themeName': s.themeName,
      'mangaWebtoon':
          Storage.setting('mangaWebtoon', defaultValue: false) == true,
    };
  }

  static Map<String, Map<String, Object>> decode(dynamic raw) {
    if (raw == null) return const {};
    const error = FormatException('备份中的阅读设置无效，请重新导出。');
    if (raw is! Map) throw error;
    final result = <String, Map<String, Object>>{};
    for (final entry in raw.entries) {
      if (!platforms.contains(entry.key) || entry.value is! Map) throw error;
      final profile = <String, Object>{};
      for (final setting in (entry.value as Map).entries) {
        final key = setting.key;
        final value = setting.value;
        final range = ranges[key];
        if (range != null) {
          if (value is! num ||
              !value.isFinite ||
              value < range.$1 ||
              value > range.$2) {
            throw error;
          }
          profile[key as String] = value.toDouble();
        } else if (booleans.contains(key)) {
          if (value is! bool) throw error;
          profile[key as String] = value;
        } else if (key == 'novel_fontWeightIndex') {
          if (value is! int || value < 0 || value > 2) throw error;
          profile[key as String] = value;
        } else if (key == 'novel_fontName') {
          if (!ReaderFont.options.any((font) => font.name == value)) {
            throw error;
          }
          profile[key as String] = value as String;
        } else if (key == 'novel_themeName') {
          if (!ReaderTheme.presets.any((theme) => theme.name == value)) {
            throw error;
          }
          profile[key as String] = value as String;
        } else {
          throw error;
        }
      }
      result[entry.key as String] = Map.unmodifiable(profile);
    }
    return Map.unmodifiable(result);
  }
}
