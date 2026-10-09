import '../models/models.dart';
import 'extension_manager.dart';
import 'local_library.dart';
import 'offline_cache.dart';

/// Resolves content for a shelf item, whether it came from a web extension or
/// from the device. Readers call through here so they never branch on origin.
class Sources {
  static CommentScope? commentScope(MediaItem item) {
    if (LocalLibrary.isLocal(item.package)) return null;
    return ExtensionManager.instance.byPackage(item.package)?.meta.commentScope;
  }

  static Future<MediaDetail> detail(MediaItem item) async {
    if (LocalLibrary.isLocal(item.package)) return LocalLibrary.detail(item);
    try {
      final service = await ExtensionManager.instance.ensureLoaded(
        item.package,
      );
      final detail = await service.detail(item.url);
      // Refresh catalogs for works downloaded with this or an older version.
      await OfflineCache.saveDetail(item, detail);
      return detail;
    } catch (_) {
      final cached = OfflineCache.readDetail(item);
      if (cached != null) return cached;
      rethrow;
    }
  }

  static Future<Map> watch(MediaItem item, String episodeUrl) async {
    if (LocalLibrary.isLocal(item.package)) {
      return LocalLibrary.watch(item, episodeUrl);
    }
    final service = await ExtensionManager.instance.ensureLoaded(item.package);
    return service.watch(episodeUrl);
  }

  /// Same as [watch] but serves a downloaded copy when one exists, so cached
  /// episodes open instantly and keep working offline.
  static Future<Map> watchCached(MediaItem item, String episodeUrl) async {
    final cached = OfflineCache.read(item.package, episodeUrl);
    // Older linovelib versions saved the site's short error preview as a novel.
    // Keep that data for rollback, but fetch a complete chapter when reading it.
    final truncatedPreview =
        cached != null &&
        item.package == 'linovelib' &&
        NovelWatch.fromJson(cached).textLines.any(
          (line) => RegExp('內容加載失敗|内容加载失败|本章内容被站点截断').hasMatch(line),
        );
    if (cached != null && !truncatedPreview) return cached;
    return watch(item, episodeUrl);
  }

  /// Display name for the badge on cards and the detail page.
  static String displayName(String package) {
    if (LocalLibrary.isLocal(package)) return '本地';
    return ExtensionManager.instance.byPackage(package)?.meta.name ?? package;
  }
}
