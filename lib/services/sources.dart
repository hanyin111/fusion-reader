import '../models/models.dart';
import 'extension_manager.dart';
import 'local_library.dart';
import 'offline_cache.dart';

/// Resolves content for a shelf item, whether it came from a web extension or
/// from the device. Readers call through here so they never branch on origin.
class Sources {
  static Future<MediaDetail> detail(MediaItem item) async {
    if (LocalLibrary.isLocal(item.package)) return LocalLibrary.detail(item);
    final service = await ExtensionManager.instance.ensureLoaded(item.package);
    return service.detail(item.url);
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
    if (cached != null) return cached;
    return watch(item, episodeUrl);
  }

  /// Display name for the badge on cards and the detail page.
  static String displayName(String package) {
    if (LocalLibrary.isLocal(package)) return '本地';
    return ExtensionManager.instance.byPackage(package)?.meta.name ?? package;
  }
}
