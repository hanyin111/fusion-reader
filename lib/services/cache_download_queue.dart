import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/models.dart';

enum CacheTaskState {
  queued,
  downloading,
  cancelling,
  completed,
  failed,
  cancelled,
}

class CacheDownloadTask {
  final MediaItem item;
  final MediaEpisode episode;
  final MediaDetail? detail;
  final Completer<void> _finished = Completer<void>();
  CacheTaskState _state = CacheTaskState.queued;
  String? _error;

  CacheDownloadTask(this.item, this.episode, this.detail);

  String get key => '${item.package}|${episode.url}';
  CacheTaskState get state => _state;
  String? get error => _error;
  Future<void> get finished => _finished.future;
  bool get isActive => switch (_state) {
    CacheTaskState.queued ||
    CacheTaskState.downloading ||
    CacheTaskState.cancelling => true,
    _ => false,
  };
}

/// Owns the batch independently of any page. One chapter runs at a time,
/// including batches submitted from different works.
class CacheDownloadQueue extends ChangeNotifier {
  final Future<void> Function(CacheDownloadTask) download;
  final bool Function(MediaItem, MediaEpisode) isCached;
  final void Function(String) cancelDownload;
  final _tasks = <String, CacheDownloadTask>{};
  final _pending = Queue<CacheDownloadTask>();
  bool _running = false;

  CacheDownloadQueue({
    required this.download,
    required this.isCached,
    required this.cancelDownload,
  });

  List<CacheDownloadTask> get tasks => List.unmodifiable(_tasks.values);
  int get activeCount => _tasks.values.where((task) => task.isActive).length;
  CacheDownloadTask? taskOf(String key) => _tasks[key];

  CacheDownloadTask? enqueue(
    MediaItem item,
    MediaEpisode episode, {
    MediaDetail? detail,
  }) {
    final key = '${item.package}|${episode.url}';
    final existing = _tasks[key];
    if (existing?.isActive == true) return existing;
    if (isCached(item, episode)) return null;
    final task = CacheDownloadTask(item, episode, detail);
    _tasks[key] = task;
    _pending.add(task);
    notifyListeners();
    if (!_running) unawaited(_drain());
    return task;
  }

  int enqueueAll(
    MediaItem item,
    Iterable<MediaEpisode> episodes, {
    MediaDetail? detail,
  }) {
    var count = 0;
    for (final episode in episodes) {
      if (taskOf('${item.package}|${episode.url}')?.isActive == true) continue;
      if (enqueue(item, episode, detail: detail) != null) count++;
    }
    return count;
  }

  Future<void> cancel(String key) async {
    final task = _tasks[key];
    if (task == null || !task.isActive) return;
    if (task.state == CacheTaskState.queued) {
      _pending.remove(task);
      task._state = CacheTaskState.cancelled;
      task._finished.complete();
    } else if (task.state == CacheTaskState.downloading) {
      task._state = CacheTaskState.cancelling;
      cancelDownload(key);
    }
    notifyListeners();
    await task.finished;
  }

  Future<void> cancelAll() async {
    await Future.wait([
      for (final task in tasks)
        if (task.isActive) cancel(task.key),
    ]);
  }

  void retry(String key) {
    final task = _tasks[key];
    if (task == null || task.isActive) return;
    enqueue(task.item, task.episode, detail: task.detail);
  }

  void forget(String key) {
    if (_tasks[key]?.isActive == true) return;
    _tasks.remove(key);
    notifyListeners();
  }

  void clearFinished() {
    _tasks.removeWhere((_, task) => !task.isActive);
    notifyListeners();
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final task = _pending.removeFirst();
        task._state = CacheTaskState.downloading;
        notifyListeners();
        try {
          if (!isCached(task.item, task.episode)) await download(task);
          task._state = task.state == CacheTaskState.cancelling
              ? CacheTaskState.cancelled
              : CacheTaskState.completed;
        } catch (error) {
          if (task.state == CacheTaskState.cancelling) {
            task._state = CacheTaskState.cancelled;
          } else {
            task._state = CacheTaskState.failed;
            task._error = error.toString();
          }
        } finally {
          task._finished.complete();
          notifyListeners();
        }
      }
    } finally {
      _running = false;
    }
  }
}
