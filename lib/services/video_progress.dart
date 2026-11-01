import '../models/models.dart';

Duration videoResumePosition(HistoryRecord? history, String episodeUrl) =>
    history != null && history.episodeUrl == episodeUrl && history.position > 0
    ? Duration(milliseconds: history.position)
    : Duration.zero;

/// Keeps the current episode's timeline independent of transient zeroes from
/// opening/changing encodings, and bounds disk writes during playback.
class VideoProgressSession {
  final HistoryRecord record;
  final Future<void> Function(HistoryRecord) write;
  final DateTime Function() now;
  final Duration interval;
  late Duration position = Duration(milliseconds: record.position);
  DateTime? _savedAt;
  int? _savedPosition;
  Future<void> _pending = Future.value();

  VideoProgressSession({
    required this.record,
    required this.write,
    DateTime Function()? now,
    this.interval = const Duration(seconds: 5),
  }) : now = now ?? DateTime.now;

  void update(Duration value) {
    if (!value.isNegative) position = value;
  }

  Future<void> save({bool force = false}) {
    final current = now();
    if (_savedPosition == position.inMilliseconds ||
        (!force &&
            _savedAt != null &&
            current.difference(_savedAt!) < interval)) {
      return _pending;
    }
    final snapshot = record.copyWith(
      position: position.inMilliseconds,
      timestamp: current.millisecondsSinceEpoch,
    );
    _savedPosition = snapshot.position;
    _savedAt = current;
    // A final save must run after an earlier asynchronous write, never before.
    _pending = _pending.catchError((Object _) {}).then((_) async {
      try {
        await write(snapshot);
      } catch (_) {
        _savedPosition = null;
        _savedAt = null;
        rethrow;
      }
    });
    return _pending;
  }
}
