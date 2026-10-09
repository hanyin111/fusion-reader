import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/extension_manager.dart';
import '../services/extension_runtime.dart';
import '../widgets/media_card.dart';
import 'extension_repository_page.dart';

/// Browse & search across sources, one tab per category.
class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        bottom: TabBar(
          controller: _tab,
          tabs: [for (final t in MediaType.values) Tab(text: t.label)],
        ),
      ),
      body: ListenableBuilder(
        listenable: ExtensionManager.instance,
        builder: (context, _) => TabBarView(
          controller: _tab,
          children: [for (final t in MediaType.values) ExploreTab(type: t)],
        ),
      ),
    );
  }
}

class ExploreTab extends StatefulWidget {
  final MediaType type;
  const ExploreTab({super.key, required this.type});

  @override
  State<ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends State<ExploreTab>
    with AutomaticKeepAliveClientMixin {
  String? _package;
  String _keyword = '';
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  final List<MediaItem> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _end = false;
  String? _error;

  List<MediaChannel> _channels = const [];
  String? _channelKey;
  ExtensionService? _observedService;
  int _listGeneration = 0;

  @override
  bool get wantKeepAlive => true;

  List<ExtensionService> get _sources =>
      ExtensionManager.instance.byType(widget.type);

  ExtensionService? get _current {
    final sources = _sources;
    if (sources.isEmpty) return null;
    return sources.firstWhere(
      (s) => s.meta.package == _package,
      orElse: () => sources.first,
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      if (_scrollCtrl.position.pixels >
              _scrollCtrl.position.maxScrollExtent - 400 &&
          !_loading &&
          !_end) {
        _load();
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _reset({bool reloadChannels = true}) {
    setState(() {
      _listGeneration++;
      _loading = false;
      _items.clear();
      _page = 1;
      _end = false;
      _error = null;
      if (reloadChannels) {
        _channels = const [];
        _channelKey = null;
      }
    });
    if (reloadChannels) _loadChannels();
    _load();
  }

  Future<void> _loadChannels() async {
    final service = _current;
    if (service == null) return;
    final generation = _listGeneration;
    try {
      await ExtensionManager.instance.ensureLoaded(service.meta.package);
      final channels = await service.channels();
      if (!mounted ||
          generation != _listGeneration ||
          !identical(service, _current)) {
        return;
      }
      setState(() => _channels = channels);
    } catch (_) {
      // Channels are optional; browsing works without them.
    }
  }

  Future<void> _load() async {
    final service = _current;
    if (service == null || _loading) return;
    final generation = _listGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ExtensionManager.instance.ensureLoaded(service.meta.package);
      final results = _keyword.isEmpty
          ? await service.latest(_page, channel: _channelKey)
          : await service.search(_keyword, _page);
      if (!mounted || generation != _listGeneration) return;
      setState(() {
        if (results.isEmpty) {
          _end = true;
        } else {
          _items.addAll(results);
          _page += 1;
        }
      });
    } catch (e) {
      if (!mounted || generation != _listGeneration) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted && generation == _listGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final sources = _sources;
    if (sources.isEmpty) {
      _observedService = null;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('该分类下没有已启用的插件'),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ExtensionRepositoryPage(),
                ),
              ),
              icon: const Icon(Icons.extension_outlined),
              label: const Text('打开插件仓库'),
            ),
          ],
        ),
      );
    }
    final current = _current!;
    if (!identical(_observedService, current)) {
      _observedService = current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reset();
      });
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SearchBar(
            controller: _searchCtrl,
            hintText: '搜索${widget.type.label}…',
            leading: const Icon(Icons.search),
            trailing: [
              if (_keyword.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchCtrl.clear();
                    _keyword = '';
                    _reset();
                  },
                ),
            ],
            onSubmitted: (v) {
              _keyword = v.trim();
              _reset();
            },
          ),
        ),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final s in sources)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.meta.name),
                    selected: s.meta.package == current.meta.package,
                    onSelected: (_) {
                      _package = s.meta.package;
                      _reset();
                    },
                  ),
                ),
            ],
          ),
        ),
        // Channel chips only appear for sources that publish them, and only
        // while browsing — a keyword search spans the whole source.
        if (_channels.isNotEmpty && _keyword.isEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final channel in _channels)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(channel.title),
                      selected:
                          _channelKey == channel.key ||
                          (_channelKey == null && channel == _channels.first),
                      onSelected: (_) {
                        _channelKey = channel.key;
                        _reset(reloadChannels: false);
                      },
                    ),
                  ),
              ],
            ),
          ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              Text(
                '加载失败，请检查网络或稍后重试\n$_error',
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _reset, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(child: Text('没有内容'));
    }
    return GridView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        childAspectRatio: 0.55,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _items.length + (_loading || !_end ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(8),
              child: CircularProgressIndicator(),
            ),
          );
        }
        return MediaCard(item: _items[i], showTypeBadge: false);
      },
    );
  }
}
