enum UpdatePlatform { android, windows, ios, other }

class AppVersion implements Comparable<AppVersion> {
  final int major, minor, patch;
  const AppVersion(this.major, this.minor, this.patch);

  static AppVersion? parse(String value) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$',
    ).firstMatch(value);
    if (match == null) return null;
    return AppVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
  }

  @override
  int compareTo(AppVersion other) {
    for (final pair in [
      [major, other.major],
      [minor, other.minor],
      [patch, other.patch],
    ]) {
      final result = pair[0].compareTo(pair[1]);
      if (result != 0) return result;
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch';
}

class AppUpdateAsset {
  final String name, checksum;
  final Uri url;
  final int size;
  const AppUpdateAsset({
    required this.name,
    required this.url,
    required this.size,
    required this.checksum,
  });
}

class AppUpdateRelease {
  static const repository = 'hanyin111/fusion-reader';
  final AppVersion version;
  final String notes;
  final Uri page;
  final AppUpdateAsset? asset;
  const AppUpdateRelease({
    required this.version,
    required this.notes,
    required this.page,
    this.asset,
  });

  factory AppUpdateRelease.parse(
    Object? raw,
    UpdatePlatform platform, {
    String? abi,
  }) {
    if (raw is! Map || raw['draft'] != false || raw['prerelease'] != false) {
      throw const FormatException('更新信息不是正式发布版本。');
    }
    final tag = raw['tag_name'];
    final version = tag is String ? AppVersion.parse(tag) : null;
    if (version == null || tag != 'v$version' || raw['assets'] is! List) {
      throw const FormatException('更新信息格式不正确。');
    }
    final page = Uri.parse('https://github.com/$repository/releases/tag/$tag');
    final name = switch (platform) {
      UpdatePlatform.android
          when const ['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains(abi) =>
        'FusionReader-$version-android-$abi.apk',
      UpdatePlatform.windows => 'FusionReader-$version-windows-x64.zip',
      UpdatePlatform.ios => 'FusionReader-ios-unsigned.ipa',
      _ => null,
    };
    AppUpdateAsset? asset;
    for (final item in raw['assets'] as List) {
      if (item is! Map || item['name'] != name || item['state'] != 'uploaded') {
        continue;
      }
      final uri = item['browser_download_url'] is String
          ? Uri.tryParse(item['browser_download_url'])
          : null;
      final size = item['size'];
      final digest = item['digest'];
      // Fail closed if GitHub has not supplied a digest; do not install an
      // unverified or mismatched package. No token or update server is needed.
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path != '/$repository/releases/download/$tag/$name' ||
          size is! int ||
          size <= 0 ||
          size > 512 * 1024 * 1024 ||
          digest is! String ||
          !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
        continue;
      }
      if (asset != null) throw const FormatException('更新信息包含重复安装包。');
      asset = AppUpdateAsset(
        name: name!,
        url: uri,
        size: size,
        checksum: digest.substring(7).toLowerCase(),
      );
    }
    final notes = raw['body'] is String ? raw['body'] as String : '';
    return AppUpdateRelease(
      version: version,
      page: page,
      asset: asset,
      notes: notes.length > 20000 ? notes.substring(0, 20000) : notes,
    );
  }
}
