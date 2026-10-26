import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const interactionPreviewKey = ValueKey('interaction-preview');

Future<void> loadInteractionPreviewFonts() async {
  if (!const bool.fromEnvironment('UI_PREVIEW')) return;
  for (final family in ['Ahem', 'Roboto']) {
    await (FontLoader(family)..addFont(
          File(
            const String.fromEnvironment('PREVIEW_FONT'),
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  }
  await (FontLoader('MaterialIcons')..addFont(
        File(
          const String.fromEnvironment('PREVIEW_ICONS'),
        ).readAsBytes().then(ByteData.sublistView),
      ))
      .load();
}

Future<void> captureInteractionPreview(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('UI_PREVIEW')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(interactionPreviewKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('dist/interaction-preview').create(recursive: true);
    await File(
      'dist/interaction-preview/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
