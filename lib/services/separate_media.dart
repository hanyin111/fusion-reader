import 'dart:convert';

/// mpv's EDL joins tracks on one timeline without transcoding or downloading
/// the whole stream. Length quoting preserves commas, semicolons and UTF-8.
String separateMediaPlaylist(String video, String audio) {
  String quote(String value) => '%${utf8.encode(value).length}%$value';
  return '# mpv EDL v0\n!new_stream\n!no_clip\n${quote(video)}\n'
      '!new_stream\n!no_clip\n${quote(audio)}\n';
}
