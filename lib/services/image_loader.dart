import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'network.dart';

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
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {...?headers},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    return _DioResponse(response, url);
  }
}

class _DioResponse implements FileServiceResponse {
  final Response<ResponseBody> _response;
  final String _url;
  final DateTime _received = DateTime.now();

  _DioResponse(this._response, this._url);

  @override
  Stream<List<int>> get content =>
      _response.data?.stream.map((e) => e.toList()) ?? const Stream.empty();

  @override
  int? get contentLength {
    final v = _response.headers.value('content-length');
    return v == null ? null : int.tryParse(v);
  }

  @override
  String? get eTag => _response.headers.value('etag');

  @override
  String get fileExtension {
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

  /// Fetch raw bytes through the source's route (used by descrambling readers).
  static Future<Uint8List> fetchBytes(
    String package,
    String url, {
    Map<String, String>? headers,
    String? netMode,
  }) async {
    final dio = netMode == null
        ? Network.forPackage(package)
        : (netMode == 'direct' ? Network.direct : Network.proxied);
    final response = await dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: headers,
      ),
    );
    return Uint8List.fromList(response.data ?? const []);
  }
}
