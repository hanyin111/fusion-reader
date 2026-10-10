import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/widgets/manga_zoom_view.dart';

Future<void> pinch(WidgetTester tester) async {
  final one = await tester.startGesture(const Offset(130, 300), pointer: 1);
  final two = await tester.startGesture(const Offset(270, 300), pointer: 2);
  await tester.pump();
  for (var i = 1; i <= 5; i++) {
    await one.moveTo(Offset(130 - i * 20, 300));
    await two.moveTo(Offset(270 + i * 20, 300));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await one.up();
  await two.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'pinch and double tap zoom without turning pages or opening the menu; reset restores swipes',
    (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey<MangaZoomViewState>();
      final pages = PageController();
      addTearDown(pages.dispose);
      var page = 0;
      var taps = 0;
      var percent = 100;
      await tester.pumpWidget(
        MaterialApp(
          home: GestureDetector(
            onTap: () => taps++,
            child: MangaZoomView(
              key: key,
              onZoomChanged: (value) => percent = value,
              builder: (scrolling) => PageView(
                controller: pages,
                physics: scrolling
                    ? null
                    : const NeverScrollableScrollPhysics(),
                onPageChanged: (value) => page = value,
                children: const [
                  ColoredBox(color: Colors.red),
                  ColoredBox(color: Colors.blue),
                ],
              ),
            ),
          ),
        ),
      );
      await pinch(tester);
      expect(percent, greaterThan(150));
      expect(page, 0);
      expect(taps, 0);
      final transform = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      final before = transform.value.clone();
      await tester.dragFrom(const Offset(200, 300), const Offset(60, 30));
      await tester.pumpAndSettle();
      expect(transform.value, isNot(before));
      expect(page, 0);
      key.currentState!.reset();
      await tester.pump();
      expect(percent, 100);
      await tester.dragFrom(const Offset(330, 300), const Offset(-290, 0));
      await tester.pumpAndSettle();
      expect(page, 1);
      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(percent, 250);
      expect(taps, 0);
      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(percent, 100);
      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(taps, 1);
    },
  );

  testWidgets(
    'webtoon zoom pans the visible area and normal vertical scrolling returns after reset',
    (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey<MangaZoomViewState>();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var percent = 100;
      await tester.pumpWidget(
        MaterialApp(
          home: MangaZoomView(
            key: key,
            onZoomChanged: (value) => percent = value,
            builder: (scrolling) => ListView.builder(
              controller: scroll,
              physics: scrolling ? null : const NeverScrollableScrollPhysics(),
              itemCount: 20,
              itemBuilder: (_, i) =>
                  SizedBox(height: 500, child: Text('page $i')),
            ),
          ),
        ),
      );
      await pinch(tester);
      expect(percent, greaterThan(150));
      await tester.dragFrom(const Offset(200, 400), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      key.currentState!.reset();
      await tester.pump();
      await tester.dragFrom(const Offset(200, 400), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      for (var i = 0; i < 10; i++) {
        key.currentState!.zoomIn();
      }
      await tester.pump();
      expect(percent, 500);
      for (var i = 0; i < 10; i++) {
        key.currentState!.zoomOut();
      }
      await tester.pump();
      expect(percent, 100);
      expect(tester.takeException(), isNull);
    },
  );
}
