import 'package:flutter/material.dart';

import '../models/reader_settings.dart';

/// Reading-preference panel for the novel reader.
///
/// Edits apply immediately rather than on confirm: the sheet only covers the
/// lower part of the screen, so the effect of every change is visible in the
/// text above it while adjusting.
class NovelSettingsSheet extends StatefulWidget {
  final NovelReaderSettings settings;
  final VoidCallback onChanged;

  const NovelSettingsSheet({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  static Future<void> show(
    BuildContext context,
    NovelReaderSettings settings,
    VoidCallback onChanged,
  ) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // Keep the page visible behind the sheet so edits can be judged live.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.62,
        maxWidth: 640,
      ),
      builder: (_) => NovelSettingsSheet(settings: settings, onChanged: onChanged),
    );
  }

  @override
  State<NovelSettingsSheet> createState() => _NovelSettingsSheetState();
}

class _NovelSettingsSheetState extends State<NovelSettingsSheet> {
  NovelReaderSettings get s => widget.settings;

  void _apply(VoidCallback change) {
    setState(change);
    widget.onChanged();
    s.save();
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 68, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (v) => _apply(() => onChanged(v)),
          ),
        ),
        SizedBox(
          width: 46,
          child: Text(display,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontFeatures: [])),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Row(
          children: [
            const Text('阅读设置',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('恢复默认'),
              onPressed: () => _apply(() => s.resetToDefaults()),
            ),
          ],
        ),

        _sectionLabel('文字'),
        _slider(
          label: '字号',
          value: s.fontSize,
          min: 12,
          max: 40,
          divisions: 28,
          display: s.fontSize.toStringAsFixed(0),
          onChanged: (v) => s.fontSize = v,
        ),
        _slider(
          label: '字重',
          value: s.fontWeightIndex.toDouble(),
          min: 0,
          max: 2,
          divisions: 2,
          display: const ['常规', '中等', '加粗'][s.fontWeightIndex.clamp(0, 2)],
          onChanged: (v) => s.fontWeightIndex = v.round(),
        ),
        _slider(
          label: '字间距',
          value: s.letterSpacing,
          min: 0,
          max: 6,
          divisions: 12,
          display: s.letterSpacing.toStringAsFixed(1),
          onChanged: (v) => s.letterSpacing = v,
        ),

        _sectionLabel('排版'),
        _slider(
          label: '行距',
          value: s.lineHeight,
          min: 1.0,
          max: 2.6,
          divisions: 16,
          display: s.lineHeight.toStringAsFixed(2),
          onChanged: (v) => s.lineHeight = v,
        ),
        _slider(
          label: '段间距',
          value: s.paragraphSpacing,
          min: 0,
          max: 40,
          divisions: 20,
          display: s.paragraphSpacing.toStringAsFixed(0),
          onChanged: (v) => s.paragraphSpacing = v,
        ),
        _slider(
          label: '左右边距',
          value: s.horizontalPadding,
          min: 0,
          max: 80,
          divisions: 20,
          display: s.horizontalPadding.toStringAsFixed(0),
          onChanged: (v) => s.horizontalPadding = v,
        ),
        _slider(
          label: '上下边距',
          value: s.verticalPadding,
          min: 0,
          max: 80,
          divisions: 20,
          display: s.verticalPadding.toStringAsFixed(0),
          onChanged: (v) => s.verticalPadding = v,
        ),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('首行缩进', style: TextStyle(fontSize: 13)),
                value: s.indentFirstLine,
                onChanged: (v) => _apply(() => s.indentFirstLine = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('两端对齐', style: TextStyle(fontSize: 13)),
                value: s.justify,
                onChanged: (v) => _apply(() => s.justify = v),
              ),
            ),
          ],
        ),

        _sectionLabel('字体'),
        Wrap(
          spacing: 8,
          children: [
            for (final font in ReaderFont.options)
              ChoiceChip(
                label: Text(font.name,
                    style: TextStyle(fontFamily: font.family, fontSize: 13)),
                selected: s.fontName == font.name,
                onSelected: (_) => _apply(() => s.fontName = font.name),
              ),
          ],
        ),

        _sectionLabel('背景'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final theme in ReaderTheme.presets)
              _ThemeSwatch(
                theme: theme,
                selected: s.themeName == theme.name,
                onTap: () => _apply(() => s.themeName = theme.name),
              ),
          ],
        ),
      ],
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  final ReaderTheme theme;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeSwatch({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = theme.isFollowApp ? scheme.surface : theme.background;
    final foreground = theme.isFollowApp ? scheme.onSurface : theme.text;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 76,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Text('文', style: TextStyle(color: foreground, fontSize: 18)),
            const SizedBox(height: 2),
            Text(theme.name,
                style: TextStyle(color: foreground, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
