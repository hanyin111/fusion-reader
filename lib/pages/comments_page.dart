import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/extension_manager.dart';
import '../services/sources.dart';
import '../widgets/source_image.dart';

class CommentsPage extends StatefulWidget {
  final MediaItem item;
  final MediaEpisode? episode;
  final CommentScope scope;
  final MediaComment? parent;

  const CommentsPage({
    super.key,
    required this.item,
    required this.scope,
    this.episode,
    this.parent,
  });

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  final _scroll = ScrollController();
  final _comments = <MediaComment>[];
  final _seen = <String>{};
  final _revealed = <String>{};
  Map<String, String> _headers = const {};
  int _page = 1;
  int? _total;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 300 && _error == null) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading || (!refresh && !_hasMore)) return;
    setState(() {
      _loading = true;
      _error = null;
      if (refresh) {
        _comments.clear();
        _seen.clear();
        _revealed.clear();
        _page = 1;
        _total = null;
        _hasMore = true;
      }
    });
    try {
      final source = await ExtensionManager.instance.ensureLoaded(
        widget.item.package,
      );
      final result = await source.comments(
        widget.item.url,
        widget.episode?.url ?? '',
        _page,
        parentId: widget.parent?.id,
      );
      if (!mounted) return;
      setState(() {
        _comments.addAll(
          result.comments.where((comment) => _seen.add(comment.key)),
        );
        _headers = result.headers;
        _total = result.total;
        _hasMore = result.hasMore;
        _page++;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _time(String raw) {
    final date = DateTime.tryParse(raw)?.toLocal();
    if (date == null) return raw;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  Widget _comment(MediaComment comment, {bool allowReplies = true}) {
    final concealed = comment.spoiler && !_revealed.contains(comment.key);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    comment.username,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (comment.pinned)
                  const Chip(
                    label: Text('置顶'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (comment.time.isNotEmpty)
              Text(
                _time(comment.time),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            if (comment.hidden)
              const Text('该评论已被隐藏')
            else if (concealed)
              TextButton.icon(
                onPressed: () => setState(() => _revealed.add(comment.key)),
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('含剧透，点击查看'),
              )
            else ...[
              if (comment.text.isNotEmpty) SelectableText(comment.text),
              for (final image in comment.images)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: SourceImage(
                      url: image,
                      package: widget.item.package,
                      headers: _headers,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.thumb_up_outlined, size: 15),
                const SizedBox(width: 5),
                Text('${comment.likes}'),
                if (allowReplies && !comment.hidden && comment.replyCount > 0)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CommentsPage(
                          item: widget.item,
                          episode: widget.episode,
                          scope: widget.scope,
                          parent: comment,
                        ),
                      ),
                    ),
                    child: Text('查看回复（${comment.replyCount}）'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      final needsAccount = _error!.contains('未配置哔咔帐号');
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              needsAccount ? '请先在「扩展」页的哔咔设置中填写帐号和密码' : '评论加载失败，请稍后重试',
              textAlign: TextAlign.center,
            ),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('暂无评论')),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _hasMore
            ? TextButton(onPressed: _load, child: const Text('加载更多评论'))
            : const Text('已显示全部评论'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.parent == null ? widget.scope.label : '评论回复'),
        actions: [
          IconButton(
            tooltip: '刷新评论',
            onPressed: _loading ? null : () => _load(refresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: _comments.length + 2 + (widget.parent == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.item.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (widget.scope == CommentScope.chapter)
                    Text(widget.episode?.name ?? ''),
                  if (widget.scope == CommentScope.work)
                    const Text('以下为整部作品的评论，各章节共用。'),
                  Text(
                    '${Sources.displayName(widget.item.package)}${_total == null ? '' : ' · $_total 条评论'}',
                  ),
                ],
              ),
            );
          }
          if (widget.parent != null && index == 1) {
            return _comment(widget.parent!, allowReplies: false);
          }
          final commentIndex = index - (widget.parent == null ? 1 : 2);
          if (commentIndex < _comments.length) {
            return _comment(_comments[commentIndex]);
          }
          return _footer();
        },
      ),
    );
  }
}
