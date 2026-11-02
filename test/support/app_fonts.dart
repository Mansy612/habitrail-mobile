// Loads the app's bundled fonts (Nunito, Material icons) so widget tests lay
// text out like the real app instead of with the wide test font.
import 'dart:convert';

import 'package:flutter/services.dart';

Future<void> loadAppFonts() async {
  final manifest =
      json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final f in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(f['family'] as String);
    for (final a in (f['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(a['asset'] as String));
    }
    await loader.load();
  }
}
