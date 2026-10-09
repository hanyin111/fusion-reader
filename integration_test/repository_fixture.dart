import 'package:fusion_reader/services/extension_repository.dart';
import 'package:fusion_reader/services/extension_manager.dart';

// Optional live source checks use independently published plugins. The app
// runtime CI relies on local synthetic fixtures and has no repository access.
Future<String> repositoryFixture(String package) async {
  final repository = ExtensionRepository();
  final index = await repository.fetch();
  return repository.download(
    index.extensions.singleWhere((entry) => entry.package == package),
  );
}

Future<void> installRepositoryFixtures(Iterable<String> packages) async {
  final repository = ExtensionRepository();
  final index = await repository.fetch();
  for (final package in packages) {
    final entry = index.extensions.singleWhere(
      (entry) => entry.package == package,
    );
    await ExtensionManager.instance.installFromScript(
      await repository.download(entry),
    );
  }
}
