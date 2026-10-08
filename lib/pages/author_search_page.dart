import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/extension_manager.dart';
import '../services/sources.dart';
import '../widgets/media_card.dart';

/// Author results stay pinned to the work's source, including pagination/retry.
class AuthorSearchPage extends StatefulWidget {
  final MediaItem item;
  final MediaAuthor author;
  const AuthorSearchPage({super.key, required this.item, required this.author});

  @override
  State<AuthorSearchPage> createState() => _AuthorSearchPageState();
}

class _AuthorSearchPageState extends State<AuthorSearchPage> {
  final _scroll = ScrollController();
  final _items = <MediaItem>[];
  final _seen = <String>{};
  int _page = 1;
  bool _loading = false;
  bool _end = false;
  String? _error;

  String _workKey(String url) {
    final uri = Uri.tryParse(url);
    return uri == null ? url : '${uri.path}?${uri.query}';
  }

  @override
  void initState() {
    super.initState();
    _seen.add(_workKey(widget.item.url));
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400 && _error == null) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _end) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = await ExtensionManager.instance.ensureLoaded(
        widget.item.package,
      );
      // A page containing only this work (or repeated entries) must not hide
      // later works. Bound empty-page scanning when a site ignores pagination.
      for (var skipped = 0; skipped < 3; skipped++) {
        final results = await source.searchAuthor(widget.author, _page);
        if (!mounted) return;
        _page++;
        final additions = results
            .where(
              (item) =>
                  item.type == widget.item.type &&
                  _seen.add(_workKey(item.url)),
            )
            .toList();
        setState(() {
          _items.addAll(additions);
          _end = results.isEmpty;
        });
        if (_end || additions.isNotEmpty) break;
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _status() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isNotEmpty && _error == null) {
      return Center(
        child: TextButton(onPressed: _load, child: const Text('加载更多')),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error == null ? '暂未找到其他作品' : '搜索失败，请稍后重试',
              textAlign: TextAlign.center,
            ),
            if (_error != null || !_end) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: _load,
                child: Text(_error == null ? '继续查找' : '重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.author.name} 的作品')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                label: Text(Sources.displayName(widget.item.package)),
              ),
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? _status()
                : GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 150,
                          childAspectRatio: 0.55,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: _items.length + (_end ? 0 : 1),
                    itemBuilder: (context, index) => index < _items.length
                        ? MediaCard(item: _items[index], showTypeBadge: false)
                        : _status(),
                  ),
          ),
        ],
      ),
    );
  }
}
