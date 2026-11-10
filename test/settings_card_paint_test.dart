import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';

void main() {
  testWidgets(
    'hover ink stays inside rounded configuration cards in both themes',
    (tester) async {
      const backdrop = Color(0xff123456);
      const boundaryKey = ValueKey('paint-boundary');
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: boundaryKey,
              child: Scaffold(
                backgroundColor: backdrop,
                body: Center(
                  child: SizedBox(
                    width: 240,
                    height: 80,
                    child: Card.outlined(
                      child: ListTile(
                        title: const Text('Model priority'),
                        onTap: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final card = tester.getRect(find.byType(Card));
        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await pointer.addPointer(location: card.center);
        await pointer.moveTo(card.center);
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final offset =
              ((card.top.toInt() + 1) * image.width + card.left.toInt() + 1) *
              4;
          expect(
            [
              bytes.getUint8(offset),
              bytes.getUint8(offset + 1),
              bytes.getUint8(offset + 2),
            ],
            [0x12, 0x34, 0x56],
            reason: 'Hover must not paint a square behind the rounded corner',
          );
          image.dispose();
        });
        await pointer.removePointer();
      }
    },
  );
}
