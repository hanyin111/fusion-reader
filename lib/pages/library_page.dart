import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/models.dart';
import '../services/local_library.dart';
import '../services/storage.dart';
import '../widgets/media_card.dart';

/// The unified library: manga, novels and anime on one shelf.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  MediaType? _filter;

  IconData _importIcon(MediaType type) {
    switch (type) {
      case MediaType.manga:
        return Icons.image_outlined;
      case MediaType.novel:
        return Icons.description_outlined;
      case MediaType.anime:
        return Icons.movie_outlined;
    }
  }

  Future<void> _import(MediaType type) async {
    try {
      String? path;
      if (type == MediaType.manga) {
        // Comics arrive either as a folder of images or as a cbz/zip.
        final choice = await showDialog<String>(
          context: context,
          builder: (c) => SimpleDialog(
            title: const Text('导入本地漫画'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, 'dir'),
                child: const ListTile(
                  leading: Icon(Icons.folder_outlined),
                  title: Text('选择文件夹'),
                  subtitle: Text('图片文件夹，或包含多个章节子文件夹的目录'),
                ),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, 'file'),
                child: const ListTile(
                  leading: Icon(Icons.folder_zip_outlined),
                  title: Text('选择压缩包'),
                  subtitle: Text('zip / cbz'),
                ),
              ),
            ],
          ),
        );
        if (choice == null) return;
        if (choice == 'dir') {
          path = await FilePicker.platform.getDirectoryPath();
        } else {
          final res = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['zip', 'cbz'],
          );
          path = res?.files.single.path;
        }
      } else if (type == MediaType.novel) {
        final res = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['epub', 'txt'],
        );
        path = res?.files.single.path;
      } else {
        final res = await FilePicker.platform.pickFiles(type: FileType.video);
        path = res?.files.single.path;
      }

      if (path == null) return;
      final item = await LocalLibrary.import(path, type);
      // Imported items go straight onto the shelf, like a favourited series.
      if (!Storage.isFavorite(item.key)) await Storage.toggleFavorite(item);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导入: ${item.title}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          PopupMenuButton<MediaType>(
            tooltip: '导入本地内容',
            icon: const Icon(Icons.add),
            onSelected: _import,
            itemBuilder: (context) => [
              for (final t in MediaType.values)
                PopupMenuItem(
                  value: t,
                  child: Row(children: [
                    Icon(_importIcon(t), size: 18, color: typeColor(t)),
                    const SizedBox(width: 8),
                    Text('导入本地${t.label}'),
                  ]),
                ),
            ],
          ),
        ],
      ),
      body: ValueListenableBuilder(
        valueListenable: Storage.favoritesBox.listenable(),
        builder: (context, Box box, _) {
          var items = Storage.favorites();
          // Most recently read first.
          items.sort((a, b) {
            final ha = Storage.historyOf(a.key)?.timestamp ?? 0;
            final hb = Storage.historyOf(b.key)?.timestamp ?? 0;
            return hb.compareTo(ha);
          });
          if (_filter != null) {
            items = items.where((i) => i.type == _filter).toList();
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('全部'),
                      selected: _filter == null,
                      onSelected: (_) => setState(() => _filter = null),
                    ),
                    for (final t in MediaType.values)
                      ChoiceChip(
                        label: Text(t.label),
                        selected: _filter == t,
                        onSelected: (_) => setState(() => _filter = t),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: items.isEmpty
                    ? const Center(
                        child: Text(
                            '书架是空的\n去「发现」页收藏在线内容，\n或用右上角 + 导入本地文件',
                            textAlign: TextAlign.center),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 130,
                          childAspectRatio: 0.55,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final item = items[i];
                          final history = Storage.historyOf(item.key);
                          return MediaCard(
                            item: item,
                            subtitle: history != null ? '读到: ${history.episodeName}' : null,
                            onLongPress: () async {
                              final remove = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: Text(item.title),
                                  content: Text(LocalLibrary.isLocal(item.package)
                                      ? '从书架移除？（不会删除本地文件）'
                                      : '从书架移除？'),
                                  actions: [
                                    TextButton(
                                        onPressed: () => Navigator.pop(c, false),
                                        child: const Text('取消')),
                                    FilledButton(
                                        onPressed: () => Navigator.pop(c, true),
                                        child: const Text('移除')),
                                  ],
                                ),
                              );
                              if (remove == true) {
                                await Storage.toggleFavorite(item);
                                // Imported entries also leave the local index;
                                // the file itself is never touched.
                                if (LocalLibrary.isLocal(item.package)) {
                                  await LocalLibrary.remove(item.url);
                                }
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
