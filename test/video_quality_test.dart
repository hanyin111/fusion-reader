import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/player_config.dart';
import 'package:fusion_reader/services/video_quality.dart';
import 'package:media_kit/media_kit.dart';

const _master = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Main, Stereo",DEFAULT=YES,AUTOSELECT=YES,URI="audio/index.m3u8"
#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=850000,BANDWIDTH=900000,RESOLUTION=640x360,CODECS="avc1.42e01e,mp4a.40.2",AUDIO="audio"
low/index.m3u8?token=one
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.42e01e,mp4a.40.2",AUDIO="audio"
/high/index.m3u8?token=two
#EXT-X-STREAM-INF:BANDWIDTH=96000,CODECS="mp4a.40.2"
/audio-only.m3u8
''';

const _media = '''#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MAP:URI="init.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="/key.bin?token=key"
#EXTINF:6,
segment.ts?token=segment
#EXT-X-ENDLIST
''';

class _Playlists implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final Map<String, String> bodies = {};
  Uri? redirect;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = bodies[options.uri.toString()];
    return ResponseBody.fromString(
        body ?? 'not found',
        body == null ? 404 : 200,
        headers: {
          Headers.contentTypeHeader: ['application/vnd.apple.mpegurl'],
        },
      )
      ..redirects = redirect != null && options.path.endsWith('master.m3u8')
          ? [RedirectRecord(302, 'GET', redirect!)]
          : [];
  }

  @override
  void close({bool force = false}) {}
}

class _FakePlayer extends PlatformPlayer {
  _FakePlayer() : super(configuration: const PlayerConfiguration());
  Media? opened;
  bool? autoplay;
  bool stopped = false;
  @override
  Future<void> stop() async {
    stopped = true;
    state = PlayerState();
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened = playable as Media;
    autoplay = play;
    state = PlayerState();
  }

  @override
  Future<void> setRate(double rate) async => state = state.copyWith(rate: rate);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const watch = AnimeWatch(
    type: 'hls',
    url: 'https://video.example/catalog/master.m3u8',
    headers: {'Referer': 'https://reader.example', 'X-Token': 'test-token'},
    netMode: 'direct',
  );
  late _Playlists adapter;
  late Dio client;
  late Directory directory;
  setUp(() async {
    adapter = _Playlists()..bodies[watch.url] = _master;
    client = Dio()..httpClientAdapter = adapter;
    directory = await Directory.systemTemp.createTemp('fusion_quality_test_');
  });
  tearDown(() async {
    client.close(force: true);
    await directory.delete(recursive: true);
  });

  test('master variants preserve signed URLs, codecs and external audio', () {
    final master = HlsMaster.parse(watch.url, _master);
    expect(master.variants.length, 2);
    expect(
      master.variants.first.url,
      'https://video.example/high/index.m3u8?token=two',
    );
    expect(
      master.variants.last.url,
      'https://video.example/catalog/low/index.m3u8?token=one',
    );
    expect(master.variants.last.bandwidth, 900000);
    expect(master.variants.last.attributes['CODECS'], 'avc1.42e01e,mp4a.40.2');
    expect(master.labelFor(master.variants.first), '720P');
    expect(hlsAttributes(_master.split('\n')[1])['NAME'], 'Main, Stereo');
  });

  test(
    'equal heights use bitrate labels; missing resolutions do not invent them',
    () {
      final master = HlsMaster.parse(watch.url, '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
a.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720
b.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=500000
c.m3u8
''');
      expect(master.variants.map(master.labelFor), [
        '720P · 2.0 Mbps',
        '720P · 1.0 Mbps',
        '500 kbps',
      ]);
    },
  );

  test(
    'discovery follows redirect base and inherits headers and routing',
    () async {
      adapter.redirect = Uri.parse('https://cdn.example/path/master.m3u8');
      final qualities = await resolveVideoQualities(
        'test',
        watch,
        client: client,
      );
      expect(qualities.map((quality) => quality.label), ['720P', '360P']);
      expect(
        qualities.last.watch.url,
        'https://cdn.example/path/low/index.m3u8?token=one',
      );
      expect(qualities.first.watch.netMode, 'direct');
      expect(qualities.first.watch.headers, watch.headers);
      expect(adapter.requests.single.headers['X-Token'], 'test-token');
    },
  );

  test(
    'selected variant stages its own audio, keys and segment base',
    () async {
      final qualities = await resolveVideoQualities(
        'test',
        watch,
        client: client,
      );
      final low = qualities.last;
      adapter.bodies[low.watch.url] = _media;
      adapter.bodies['https://video.example/catalog/audio/index.m3u8'] = _media;
      final media = await buildMedia(
        'test',
        watch,
        quality: low,
        client: client,
        playlistDirectory: directory,
        fallback: false,
      );
      final result = await File(media.uri).readAsString();
      expect(result, contains('RESOLUTION=640x360'));
      expect(result, isNot(contains('RESOLUTION=1280x720')));
      expect(result, contains('AUDIO="audio"'));
      final audioPath = RegExp(r'URI="([^"]+)"').firstMatch(result)!.group(1)!;
      expect(File(audioPath).existsSync(), isTrue);
      final staged = await Future.wait(
        directory.listSync().whereType<File>().map(
          (file) => file.readAsString(),
        ),
      );
      expect(
        staged.any(
          (body) => body.contains(
            'https://video.example/catalog/low/segment.ts?token=segment',
          ),
        ),
        isTrue,
      );
      expect(
        staged.any(
          (body) => body.contains(
            'https://video.example/catalog/audio/segment.ts?token=segment',
          ),
        ),
        isTrue,
      );
      expect(
        staged.any(
          (body) =>
              body.contains('URI="https://video.example/key.bin?token=key"'),
        ),
        isTrue,
      );
      expect(
        adapter.requests.where((request) => request.uri.path.contains('high')),
        isEmpty,
      );
      expect(
        adapter.requests.every(
          (request) => request.headers['X-Token'] == 'test-token',
        ),
        isTrue,
      );
    },
  );

  test(
    'manual selection fails rather than silently switching to another encoding',
    () async {
      final qualities = await resolveVideoQualities(
        'test',
        watch,
        client: client,
      );
      await expectLater(
        buildMedia(
          'test',
          watch,
          quality: qualities.last,
          client: client,
          playlistDirectory: directory,
          fallback: false,
        ),
        throwsA(isA<DioException>()),
      );
    },
  );

  test('cyclic masters are bounded instead of loading forever', () async {
    adapter.bodies[watch.url] =
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmaster.m3u8';
    await expectLater(
      buildMedia(
        'test',
        watch,
        client: client,
        playlistDirectory: directory,
        fallback: false,
      ),
      throwsFormatException,
    );
    expect(adapter.requests.length, lessThanOrEqualTo(5));
  });

  test('legacy MP4 and cached HLS do not trigger discovery requests', () async {
    for (final video in [
      const AnimeWatch(type: 'mp4', url: 'https://video.example/movie.mp4'),
      AnimeWatch(type: 'hls', url: '${directory.path}/offline.m3u8'),
    ]) {
      final qualities = await resolveVideoQualities(
        'test',
        video,
        client: client,
      );
      expect(qualities.single.label, '原画');
      final media = await buildMedia(
        'test',
        video,
        quality: qualities.single,
        client: client,
        playlistDirectory: directory,
      );
      expect(media.uri, Media.normalizeURI(video.url));
    }
    expect(adapter.requests, isEmpty);
  });

  test('invalid discovery keeps original playback URL', () async {
    adapter.bodies[watch.url] = '<html>unavailable</html>';
    final qualities = await resolveVideoQualities(
      'test',
      watch,
      client: client,
    );
    expect(qualities.single.watch.url, watch.url);
  });

  test(
    'optional source qualities reject bad URLs and merge headers case-insensitively',
    () async {
      final video = AnimeWatch.fromJson({
        'type': 'mp4',
        'url': 'https://video.example/movie.mp4',
        'headers': {'Referer': 'old', 'X-Token': 'test-token'},
        'netMode': 'direct',
        'qualities': [
          {'label': '1080P', 'url': 'https://video.example/movie.mp4'},
          {
            'label': '720P',
            'url': 'https://video.example/720.mp4',
            'headers': {'referer': 'new'},
          },
          {'url': 'file:///not-allowed'},
          null,
          {'url': 'javascript:alert(1)'},
        ],
      });
      final qualities = await resolveVideoQualities(
        'test',
        video,
        client: client,
      );
      expect(qualities.map((quality) => quality.label), ['1080P', '720P']);
      expect(qualities.last.watch.headers, {
        'referer': 'new',
        'X-Token': 'test-token',
      });
      expect(qualities.last.watch.netMode, 'direct');
      expect(adapter.requests, isEmpty);
    },
  );

  for (final playing in [true, false]) {
    test('switch preserves milliseconds, speed and playing=$playing', () async {
      final native = _FakePlayer()
        ..state = PlayerState(
          position: const Duration(milliseconds: 45123),
          playing: playing,
          rate: 1.75,
        );
      final player = Player(platformPlayer: native);
      await replaceVideoMedia(
        player,
        Media(
          'https://video.example/new.mp4',
          httpHeaders: {'X-Token': 'test-token'},
        ),
        configure: () async {
          expect(native.stopped, isTrue);
          expect(native.opened, isNull);
        },
      );
      expect(native.opened!.start, const Duration(milliseconds: 45123));
      expect(native.opened!.httpHeaders!['X-Token'], 'test-token');
      expect(native.autoplay, playing);
      expect(player.state.rate, 1.75);
      await player.dispose();
    });
  }
}
