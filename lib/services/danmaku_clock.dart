/// Interpolate sparse player position events using a monotonic clock.
/// Buffering/paused playback holds its time; speed changes keep continuity.
class DanmakuClock {
  final double Function() elapsedSeconds;
  double _anchorTime = 0, _anchorClock = 0;
  bool _playing = false, _buffering = false;
  double _rate = 1;

  DanmakuClock(this.elapsedSeconds);

  double get time =>
      _anchorTime +
      (_playing && !_buffering ? (elapsedSeconds() - _anchorClock) * _rate : 0);

  void _anchor([double? seconds]) {
    _anchorTime = seconds ?? time;
    _anchorClock = elapsedSeconds();
  }

  void position(double seconds) {
    if ((seconds - time).abs() > .15 || !_playing || _buffering) {
      _anchor(seconds);
    }
  }

  void playing(bool value) {
    _anchor();
    _playing = value;
  }

  void buffering(bool value) {
    _anchor();
    _buffering = value;
  }

  void rate(double value) {
    _anchor();
    _rate = value;
  }
}
