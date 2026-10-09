import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'network.dart';
import 'source_image_codec.dart';

/// Bridges flutter_cache_manager onto our per-source Dio clients so cover art
/// and manga pages follow the same proxy routing as the extension that
/// produced their urls.
class _DioFileService extends FileService {
  final String package;
  final String? netMode;
  _DioFileService(this.package, this.netMode);

  Dio get _dio => netMode == null
      ? Network.forPackage(package)
      : (netMode == 'direct' ? Network.direct : Network.proxied);

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final response = await _dio.get<ResponseBody>(
      SourceImageCodec.requestUrl(package, url),
      options: Options(
        responseType: ResponseType.stream,
        headers: SourceImageCodec.headersFor(package, headers),
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    Uint8List? processed;
    if (response.statusCode == 200 &&
        SourceImageCodec.episodeId(package, url) != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        builder.add(chunk);
      }
      processed = await SourceImageCodec.decode(
        package,
        url,
        builder.takeBytes(),
      );
    }
    return _DioResponse(response, url, processed);
  }
}

class _DioResponse implements FileServiceResponse {
  final Response<ResponseBody> _response;
  final String _url;
  final Uint8List? _processed;
  final DateTime _received = DateTime.now();

  _DioResponse(this._response, this._url, this._processed);

  @override
  Stream<List<int>> get content => _processed != null
      ? Stream.value(_processed)
      : _response.data?.stream.map((e) => e.toList()) ?? const Stream.empty();

  @override
  int? get contentLength {
    if (_processed != null) return _processed.length;
    final v = _response.headers.value('content-length');
    return v == null ? null : int.tryParse(v);
  }

  @override
  String? get eTag => _response.headers.value('etag');

  @override
  String get fileExtension {
    if (_processed != null &&
        _processed.length >= 8 &&
        _processed[0] == 137 &&
        _processed[1] == 80 &&
        _processed[2] == 78 &&
        _processed[3] == 71) {
      return '.png';
    }
    final type = _response.headers.value('content-type') ?? '';
    if (type.contains('png')) return '.png';
    if (type.contains('webp')) return '.webp';
    if (type.contains('gif')) return '.gif';
    if (type.contains('avif')) return '.avif';
    if (type.contains('jpeg') || type.contains('jpg')) return '.jpg';
    // Fall back to the url suffix when the server omits a useful type.
    final path = Uri.tryParse(_url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot > 0 && path.length - dot <= 6) return path.substring(dot);
    return '.jpg';
  }

  @override
  int get statusCode => _response.statusCode ?? 500;

  @override
  DateTime get validTill => _received.add(const Duration(days: 7));
}

/// Cache managers keyed by source *and* route, since a single source can serve
/// its pages and its images over different network paths.
class SourceImageCache {
  static final Map<String, CacheManager> _managers = {};

  static CacheManager of(String package, {String? netMode}) {
    final key = '$package|${netMode ?? 'auto'}';
    return _managers.putIfAbsent(
      key,
      () => CacheManager(
        Config(
          'fusion_img_${key.replaceAll('|', '_')}',
          stalePeriod: const Duration(days: 14),
          maxNrOfCacheObjects: 800,
          fileService: _DioFileService(package, netMode),
        ),
      ),
    );
  }

  /// Fetch display-ready bytes through the source's route, restoring pages
  /// when the URL carries a supported processing context.
  static Future<Uint8List> fetchBytes(
    String package,
    String url, {
    Map<String, String>? headers,
    String? netMode,
    CancelToken? cancelToken,
  }) async {
    final dio = netMode == null
        ? Network.forPackage(package)
        : (netMode == 'direct' ? Network.direct : Network.proxied);
    final response = await dio.get<List<int>>(
      SourceImageCodec.requestUrl(package, url),
      options: Options(
        responseType: ResponseType.bytes,
        headers: SourceImageCodec.headersFor(package, headers),
      ),
      cancelToken: cancelToken,
    );
    return SourceImageCodec.decode(
      package,
      url,
      Uint8List.fromList(response.data ?? const []),
    );
  }
}
