import 'package:flutter/material.dart';

import '../services/storage.dart';

/// A background/foreground pairing for the novel reader.
class ReaderTheme {
  final String name;
  final Color background;
  final Color text;

  const ReaderTheme(this.name, this.background, this.text);

  /// `null` colours mean "inherit from the app theme", which is the only way
  /// to keep the reader correct in both light and dark mode.
  static const followApp = ReaderTheme('跟随应用', Color(0x00000000), Color(0x00000000));

  bool get isFollowApp => background.a == 0 && text.a == 0;

  static const presets = <ReaderTheme>[
    followApp,
    ReaderTheme('纸白', Color(0xFFFFFFFF), Color(0xFF1A1A1A)),
    ReaderTheme('米黄', Color(0xFFF7F0DE), Color(0xFF3B3222)),
    ReaderTheme('杏仁', Color(0xFFEFE3D0), Color(0xFF43352A)),
    ReaderTheme('护眼绿', Color(0xFFCBE6CD), Color(0xFF1F2E20)),
    ReaderTheme('青灰', Color(0xFFD5DBDB), Color(0xFF22292A)),
    ReaderTheme('暗灰', Color(0xFF32363B), Color(0xFFCBD0D4)),
    ReaderTheme('纯黑', Color(0xFF000000), Color(0xFFA9AFB5)),
  ];

  static ReaderTheme byName(String name) => presets.firstWhere(
        (t) => t.name == name,
        orElse: () => followApp,
      );
}

/// A selectable typeface. `family` of null falls back to the platform default.
class ReaderFont {
  final String name;
  final String? family;
  const ReaderFont(this.name, this.family);

  static const options = <ReaderFont>[
    ReaderFont('鸿蒙黑体', 'HarmonyOS Sans SC'),
    ReaderFont('系统默认', null),
    ReaderFont('衬线', 'Noto Serif CJK SC'),
    ReaderFont('等宽', 'monospace'),
  ];

  static ReaderFont byName(String name) => options.firstWhere(
        (f) => f.name == name,
        orElse: () => options.first,
      );
}

/// Everything the novel reader lets the user tune, persisted as it changes.
class NovelReaderSettings {
  double fontSize;
  double lineHeight;
  double paragraphSpacing;
  double horizontalPadding;
  double verticalPadding;
  double letterSpacing;
  int fontWeightIndex; // 0 regular, 1 medium, 2 bold
  bool indentFirstLine;
  bool justify;
  String fontName;
  String themeName;

  NovelReaderSettings({
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.letterSpacing,
    required this.fontWeightIndex,
    required this.indentFirstLine,
    required this.justify,
    required this.fontName,
    required this.themeName,
  });

  static const _defaults = {
    'fontSize': 18.0,
    'lineHeight': 1.7,
    'paragraphSpacing': 12.0,
    'horizontalPadding': 20.0,
    'verticalPadding': 16.0,
    'letterSpacing': 0.0,
    'fontWeightIndex': 0,
    'indentFirstLine': true,
    'justify': false,
  };

  static double _d(String key) =>
      (Storage.setting('novel_$key', defaultValue: _defaults[key]) as num)
          .toDouble();

  factory NovelReaderSettings.load() => NovelReaderSettings(
        fontSize: _d('fontSize'),
        lineHeight: _d('lineHeight'),
        paragraphSpacing: _d('paragraphSpacing'),
        horizontalPadding: _d('horizontalPadding'),
        verticalPadding: _d('verticalPadding'),
        letterSpacing: _d('letterSpacing'),
        fontWeightIndex:
            Storage.setting('novel_fontWeightIndex', defaultValue: 0) as int,
        indentFirstLine:
            Storage.setting('novel_indentFirstLine', defaultValue: true) as bool,
        justify: Storage.setting('novel_justify', defaultValue: false) as bool,
        fontName: Storage.setting('novel_fontName',
            defaultValue: ReaderFont.options.first.name) as String,
        themeName: Storage.setting('novel_themeName',
            defaultValue: ReaderTheme.followApp.name) as String,
      );

  Future<void> save() async {
    await Storage.setSetting('novel_fontSize', fontSize);
    await Storage.setSetting('novel_lineHeight', lineHeight);
    await Storage.setSetting('novel_paragraphSpacing', paragraphSpacing);
    await Storage.setSetting('novel_horizontalPadding', horizontalPadding);
    await Storage.setSetting('novel_verticalPadding', verticalPadding);
    await Storage.setSetting('novel_letterSpacing', letterSpacing);
    await Storage.setSetting('novel_fontWeightIndex', fontWeightIndex);
    await Storage.setSetting('novel_indentFirstLine', indentFirstLine);
    await Storage.setSetting('novel_justify', justify);
    await Storage.setSetting('novel_fontName', fontName);
    await Storage.setSetting('novel_themeName', themeName);
  }

  void resetToDefaults() {
    fontSize = _defaults['fontSize'] as double;
    lineHeight = _defaults['lineHeight'] as double;
    paragraphSpacing = _defaults['paragraphSpacing'] as double;
    horizontalPadding = _defaults['horizontalPadding'] as double;
    verticalPadding = _defaults['verticalPadding'] as double;
    letterSpacing = _defaults['letterSpacing'] as double;
    fontWeightIndex = 0;
    indentFirstLine = true;
    justify = false;
    fontName = ReaderFont.options.first.name;
    themeName = ReaderTheme.followApp.name;
  }

  ReaderTheme get theme => ReaderTheme.byName(themeName);
  ReaderFont get font => ReaderFont.byName(fontName);

  FontWeight get fontWeight =>
      const [FontWeight.w400, FontWeight.w500, FontWeight.w700][
          fontWeightIndex.clamp(0, 2)];

  Color background(BuildContext context) => theme.isFollowApp
      ? Theme.of(context).colorScheme.surface
      : theme.background;

  Color foreground(BuildContext context) => theme.isFollowApp
      ? Theme.of(context).colorScheme.onSurface
      : theme.text;

  TextStyle textStyle(BuildContext context) => TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        letterSpacing: letterSpacing,
        fontWeight: fontWeight,
        fontFamily: font.family,
        color: foreground(context),
      );
}
