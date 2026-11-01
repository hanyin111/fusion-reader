import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/video_quality.dart';
import 'package:fusion_reader/widgets/video_quality_button.dart';

const high = VideoQuality(
  label: '1080P',
  watch: AnimeWatch(type: 'mp4', url: 'https://video.example/high.mp4'),
);
const low = VideoQuality(
  label: '720P',
  watch: AnimeWatch(type: 'mp4', url: 'https://video.example/low.mp4'),
);

void main() {
  testWidgets('menu stays responsive across a separate fullscreen route', (
    tester,
  ) async {
    final selection = ValueNotifier(
      const VideoQualitySelection(options: [high, low]),
    );
    VideoQuality? selected;
    addTearDown(selection.dispose);
    Widget button() => VideoQualityButton(
      selection: selection,
      onSelected: (value) => selected = value,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                button(),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(body: button()),
                    ),
                  ),
                  child: const Text('全屏'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('全屏'));
    await tester.pumpAndSettle();
    selection.value = const VideoQualitySelection(
      options: [high, low],
      selected: 1,
    );
    await tester.pump();
    expect(find.text('720P'), findsOneWidget);
    await tester.tap(find.byTooltip('清晰度'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<int>, '1080P'));
    await tester.pumpAndSettle();
    expect(selected, same(high));
  });

  testWidgets('single-encoding menu explains why there are no other options', (
    tester,
  ) async {
    final selection = ValueNotifier(
      const VideoQualitySelection(options: [high]),
    );
    addTearDown(selection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoQualityButton(selection: selection, onSelected: (_) {}),
        ),
      ),
    );
    await tester.tap(find.byTooltip('清晰度'));
    await tester.pumpAndSettle();
    expect(find.text('当前视频仅提供一种清晰度'), findsOneWidget);
  });

  testWidgets('busy menu blocks repeated switches', (tester) async {
    final selection = ValueNotifier(
      const VideoQualitySelection(options: [high, low], busy: true),
    );
    addTearDown(selection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoQualityButton(
            selection: selection,
            onSelected: (_) => fail('busy'),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<PopupMenuButton<int>>(find.byType(PopupMenuButton<int>))
          .enabled,
      isFalse,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
