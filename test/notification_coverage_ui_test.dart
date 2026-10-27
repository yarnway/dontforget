import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/ui/formatters/notification_coverage.dart';
import 'package:dont_forget/ui/widgets/routine_coverage_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Reminders extends StateNotifier<List<Reminder>>
    implements RemindersNotifier {
  _Reminders() : super([]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NotificationScheduleStatus status({bool covered = false, bool empty = false}) =>
    NotificationScheduleStatus(
      upcoming: empty ? 0 : 2,
      submitted: covered ? 1 : 0,
      needsAttention: empty || covered ? 0 : 1,
      cancellations: 0,
      overdueUnconfirmed: 0,
      deferred: empty ? 0 : 1,
      scheduledThrough: covered ? DateTime(2032, 1, 2, 8) : null,
      capacity: 50,
    );

void main() {
  for (final locale in ['zh', 'en', 'ja']) {
    test('coverage wording distinguishes empty and unconfirmed in $locale', () {
      final l10n = AppLocalizations(Locale(locale));
      final unconfirmed = formatNotificationCoverage(l10n, status());
      final empty = formatNotificationCoverage(l10n, status(empty: true));
      final covered = formatNotificationCoverage(l10n, status(covered: true));
      expect(
        unconfirmed,
        l10n
            .get('notificationScheduleWindowUnconfirmed')
            .replaceAll('{deferred}', '1')
            .replaceAll('{capacity}', '50'),
      );
      expect(
        empty,
        l10n
            .get('notificationScheduleWindowEmpty')
            .replaceAll('{capacity}', '50'),
      );
      expect(covered, contains('2032'));
      for (final message in [unconfirmed, empty, covered]) {
        expect(message, isNot(contains('{')));
        expect(message, isNot(contains('—')));
      }
    });
  }

  Future<void> pump(
    WidgetTester tester,
    ProviderContainer container, {
    double width = 375,
    String locale = 'zh',
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(locale),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: RoutineCoveragePanel(planId: 'commute'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ProviderContainer container(
    Future<NotificationScheduleStatus> Function(String) read,
  ) => ProviderContainer(
    overrides: [
      remindersProvider.overrideWith((_) => _Reminders()),
      routineScheduleStatusReaderProvider.overrideWithValue(read),
    ],
  );

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final locale in ['zh', 'en', 'ja']) {
      testWidgets('coverage fits $width $locale with large text', (
        tester,
      ) async {
        final scope = container((_) async => status());
        addTearDown(scope.dispose);
        await pump(tester, scope, width: width, locale: locale);
        expect(
          find.text(
            formatNotificationCoverage(
              AppLocalizations(Locale(locale)),
              status(),
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'manual refresh and returning to foreground refresh journal-only changes',
    (tester) async {
      var current = status();
      var reads = 0;
      final scope = container((_) async {
        reads++;
        return current;
      });
      addTearDown(scope.dispose);
      await pump(tester, scope);
      expect(reads, 1);
      current = status(covered: true);
      await tester.tap(find.byTooltip('刷新状态'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.textContaining('连续预排至'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 3);
    },
  );
}
