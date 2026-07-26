import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/image_loader.dart';

/// Shows an image that may live on the network or on disk.
///
/// Locally imported comics hand back plain file paths, so every image site in
/// the app has to cope with both without the caller deciding which is which.
class SourceImage extends StatelessWidget {
  final String url;
  final String package;
  final String? netMode;
  final Map<String, String>? headers;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? error;

  const SourceImage({
    super.key,
    required this.url,
    required this.package,
    this.netMode,
    this.headers,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.error,
  });

  static bool isRemote(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    final fallback = error ??
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.broken_image_outlined)),
        );

    if (url.isEmpty) return fallback;

    if (!isRemote(url)) {
      return Image.file(
        File(url),
        fit: fit,
        errorBuilder: (context, e, s) => fallback,
      );
    }

    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: SourceImageCache.of(package, netMode: netMode),
      httpHeaders: headers?.isEmpty ?? true ? null : headers,
      fit: fit,
      placeholder: placeholder == null ? null : (c, u) => placeholder!,
      progressIndicatorBuilder: placeholder != null
          ? null
          : (c, u, p) => Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child:
                      CircularProgressIndicator(value: p.progress, strokeWidth: 3),
                ),
              ),
      errorWidget: (c, u, e) => fallback,
    );
  }
}
