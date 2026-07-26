import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/home.dart';
import 'services/extension_manager.dart';
import 'services/storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Storage.init();
  // Extension load errors are collected per-extension; never blocks startup.
  await ExtensionManager.instance.init();
  runApp(const FusionApp());
}

const kFontFamily = 'HarmonyOS Sans SC';

class FusionApp extends StatelessWidget {
  const FusionApp({super.key});

  ThemeData _theme(Brightness brightness) {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: brightness,
      ),
      useMaterial3: true,
      fontFamily: kFontFamily,
    );
    // Material's own text theme still carries the default family on some
    // platforms, so apply it to every style explicitly.
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: kFontFamily),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: kFontFamily),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FusionReader 聚阅',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}
