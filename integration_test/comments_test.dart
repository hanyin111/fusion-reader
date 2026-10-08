import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/detail_page.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'author_search_test.dart' show settle;
import 'linovelib_test.dart' show isolateLinovelibTestStorage;

String fixture(
  String package,
  MediaType type,
  CommentScope scope,
  String image,
) =>
    '''
// ==MiruExtension==
// @name 评论测试
// @package $package
// @type ${type.name}
// @comments ${scope.name}
// ==/MiruExtension==
export default class extends Extension {
  firstPages = 0;
  async detail(url) { return {title:'测试作品', episodes:[{title:'章节', urls:[
    {name:'第一章',url:'/chapter/1'}, {name:'第二章',url:'/chapter/2'}]}]}; }
  async watch(url) {
    return ${type == MediaType.novel ? '{content:Array.from({length:80},(_,i)=>"第 "+i+" 段正文，测试保留阅读位置。")}' : '{urls:[${jsonEncode(image)}]}'};
  }
  async comments(work, chapter, page, parent) {
    if (work !== '/work') throw new Error('wrong work');
    if (parent) return {comments:[{id:'reply',username:'回复者',text:'回复正文'}],hasMore:false};
    if (page === 1 && ++this.firstPages === 2) throw new Error('temporary failure');
    const root = {id:'root',username:'读者甲',text:${scope == CommentScope.chapter ? 'chapter + " 章评"' : '"漫画共用评论"'},likes:3,replyCount:${scope == CommentScope.work ? 1 : 0}};
    return {comments: page === 1 ? [root,
      {id:'spoiler',username:'读者乙',text:'未来剧情',spoiler:true},
      {id:'hidden',username:'读者丙',text:'不可显示的内容',hidden:true}
    ] : [root,{id:'later',username:'读者丁',text:'下一页评论'}],hasMore:page===1,total:4};
  }
}
''';

int firstVisibleBlock(WidgetTester tester) => tester
    .widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList))
    .itemPositionsNotifier!
    .itemPositions
    .value
    .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
    .map((p) => p.index)
    .reduce((a, b) => a < b ? a : b);

void main() {
  isolateLinovelibTestStorage();
  testWidgets(
    'comments follow chapters, preserve reading and handle pagination/replies/retry',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'fusion_comments_image_',
      );
      final image = File('${temp.path}/pixel.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aO9sAAAAASUVORK5CYII=',
          ),
        );
      await tester.runAsync(() async {
        await Storage.init();
        await ExtensionManager.instance.init();
      });
      for (final type in [MediaType.novel, MediaType.manga]) {
        final scope = type == MediaType.novel
            ? CommentScope.chapter
            : CommentScope.work;
        final package = 'comments_fixture_${type.name}';
        final item = MediaItem(
          package: package,
          type: type,
          title: '测试作品',
          url: '/work',
        );
        await tester.runAsync(
          () => ExtensionManager.instance.installFromScript(
            fixture(package, type, scope, image.path),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: DetailPage(item: item),
          ),
        );
        await settle(tester);
        if (scope == CommentScope.chapter) {
          expect(find.byTooltip('章节评论'), findsNWidgets(2));
        } else {
          expect(find.text('作品评论'), findsOneWidget);
        }
        await tester.tap(find.text('第一章'));
        await settle(tester);
        int? position;
        if (type == MediaType.novel) {
          await tester.drag(
            find.byType(ScrollablePositionedList),
            const Offset(0, -400),
          );
          await settle(tester);
          position = firstVisibleBlock(tester);
          expect(position, greaterThan(0));
        }
        await tester.tap(find.byTooltip(scope.label));
        await settle(tester);
        expect(
          find.text(scope == CommentScope.chapter ? '/chapter/1 章评' : '漫画共用评论'),
          findsOneWidget,
        );
        expect(find.text('未来剧情'), findsNothing);
        expect(find.text('不可显示的内容'), findsNothing);
        await tester.tap(find.text('含剧透，点击查看'));
        await settle(tester);
        expect(find.text('未来剧情'), findsOneWidget);
        if (scope == CommentScope.work) {
          expect(find.text('以下为整部作品的评论，各章节共用。'), findsOneWidget);
          await tester.tap(find.text('查看回复（1）'));
          await settle(tester);
          expect(find.text('回复正文'), findsOneWidget);
          await tester.pageBack();
          await settle(tester);
        }
        await tester.drag(find.byType(ListView), const Offset(0, -700));
        await settle(tester);
        // On a tall desktop window the first page fits without scrolling.
        // The explicit button must work as well as scroll-triggered loading.
        if (find.text('加载更多评论').evaluate().isNotEmpty) {
          await tester.ensureVisible(find.text('加载更多评论'));
          await settle(tester);
          if (find.text('加载更多评论').evaluate().isNotEmpty) {
            await tester.tap(find.text('加载更多评论'));
            await settle(tester);
          }
        }
        expect(find.text('下一页评论'), findsOneWidget);
        expect(find.text('已显示全部评论'), findsOneWidget);
        // Refresh failure after the last page must remain retryable.
        await tester.tap(find.byTooltip('刷新评论'));
        await settle(tester);
        expect(find.text('评论加载失败，请稍后重试'), findsOneWidget);
        await tester.tap(find.text('重试'));
        await settle(tester);
        expect(
          find.text(scope == CommentScope.chapter ? '/chapter/1 章评' : '漫画共用评论'),
          findsOneWidget,
        );
        await tester.pageBack();
        await settle(tester);
        if (position != null) expect(firstVisibleBlock(tester), position);
        await tester.tap(
          type == MediaType.novel ? find.text('下一章') : find.byTooltip('下一章'),
        );
        await settle(tester);
        await tester.tap(find.byTooltip(scope.label));
        await settle(tester);
        expect(
          find.text(scope == CommentScope.chapter ? '/chapter/2 章评' : '漫画共用评论'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await settle(tester);
      await tester.runAsync(() async {
        // Remove only this test's generated image after widgets release it.
        image.deleteSync();
        temp.deleteSync();
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
