import 'package:dont_forget/ui/screens/storage_unavailable_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final busy in [true, false]) {
    testWidgets('startup failure is usable at 375px, busy=$busy', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var exited = false;
      await tester.pumpWidget(
        StorageUnavailableScreen(busy: busy, onExit: () => exited = true),
      );
      expect(find.text(busy ? '数据正在使用中' : '暂时无法打开本地数据'), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      expect(exited, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
