import 'dart:async';
import 'dart:io';

import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/recovery_coordinator.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/ui/screens/backup_preview_screen.dart';
import 'package:dont_forget/ui/screens/recovery_outcome_screen.dart';
import 'package:dont_forget/ui/widgets/recovery_confirmation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const _rollback =
    '/private/isolated-acceptance/Application Support/别忘了/recovery-1234567890/rollback.db';
const _preview = BackupPreview(
  version: 8,
  digest: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  counts: {'reminders': 12, 'media_records': 3, 'settings': 1},
  containsCredentials: true,
  missingMedia: 2,
  unresolvedReferences: 4,
);
const _currentCounts = {'reminders': 9, 'media_records': 5, 'settings': 1};
const _delegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizationsDelegate(),
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

class _Inspector implements BackupInspector {
  @override
  Future<BackupPreview> inspect(
    File source, {
    BackupInspectionCancellation? cancellation,
  }) async => _preview;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget home, {String language = 'en', double scale = 1}) =>
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
      localizationsDelegates: _delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

Future<void> _showDialog(
  WidgetTester tester, {
  String language = 'en',
  double scale = 1,
  void Function(bool?)? completed,
}) async {
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open-confirmation'),
            onPressed: () async {
              final result = await showDialog<bool>(
                context: context,
                builder: (_) => const RecoveryConfirmationDialog(
                  preview: _preview,
                  currentCounts: _currentCounts,
                  rollbackDirectory: _rollback,
                ),
              );
              completed?.call(result);
            },
            child: const Text('Open confirmation'),
          ),
        ),
      ),
      language: language,
      scale: scale,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('open-confirmation')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('confirmation counts and impact fit all widths and languages', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [375.0, 768.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 812);
      for (final language in ['zh', 'en', 'ja']) {
        final l10n = AppLocalizations(Locale(language));
        await _showDialog(tester, language: language, scale: 1.3);
        for (final key in [
          'backupRestoreReplacement',
          'backupRestoreDrafts',
          'backupRestoreLan',
          'backupRestoreFiles',
          'backupPreviewCredentials',
          'backupRestoreRollbackNotice',
        ]) {
          expect(find.text(l10n.get(key)), findsOneWidget);
        }
        for (final entry in _currentCounts.entries) {
          expect(
            tester
                .widget<Text>(
                  find.byKey(ValueKey('recovery-current-${entry.key}')),
                )
                .data,
            '${entry.value}',
          );
          expect(
            tester
                .widget<Text>(
                  find.byKey(ValueKey('recovery-candidate-${entry.key}')),
                )
                .data,
            '${_preview.counts[entry.key]}',
          );
        }
        expect(find.text(_rollback), findsOneWidget);
        expect(
          find.text('${l10n.get('backupPreviewMissingMedia')}: 2'),
          findsOneWidget,
        );
        expect(
          find.text('${l10n.get('backupPreviewUnresolved')}: 4'),
          findsOneWidget,
        );
        final confirm = find.byKey(
          const ValueKey('recovery-confirmation-confirm'),
        );
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        final acknowledge = find.byKey(const ValueKey('recovery-acknowledge'));
        await tester.ensureVisible(acknowledge);
        await tester.pumpAndSettle();
        await tester.tap(acknowledge);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$width / $language');
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets('cancel and Escape never accept recovery', (tester) async {
    final results = <bool?>[];
    await _showDialog(tester, completed: results.add);
    await tester.tap(
      find.byKey(const ValueKey('recovery-confirmation-cancel')),
    );
    await tester.pumpAndSettle();
    expect(results, [false]);
    await tester.tap(find.byKey(const ValueKey('open-confirmation')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(results, [false, null]);
    expect(find.byType(RecoveryConfirmationDialog), findsNothing);
  });

  testWidgets(
    'keyboard defaults to cancel and each opening requires acknowledgement',
    (tester) async {
      final results = <bool?>[];
      await _showDialog(tester, completed: results.add);
      final cancel = find.text(
        AppLocalizations(const Locale('en')).get('backupRestoreCancel'),
      );
      expect(Focus.of(tester.element(cancel)).hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(results, [false]);
      await tester.tap(find.byKey(const ValueKey('open-confirmation')));
      await tester.pumpAndSettle();
      final acknowledge = find.byKey(const ValueKey('recovery-acknowledge'));
      expect(tester.widget<CheckboxListTile>(acknowledge).value, isFalse);
      await tester.ensureVisible(acknowledge);
      await tester.pumpAndSettle();
      await tester.tap(acknowledge);
      await tester.pumpAndSettle();
      final confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('recovery-confirmation-confirm')),
      );
      // Repeated activation in the same frame must pop only the dialog once.
      confirm.onPressed!();
      confirm.onPressed!();
      await tester.pumpAndSettle();
      expect(results, [false, true]);
      expect(find.byKey(const ValueKey('open-confirmation')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('open-confirmation')));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(acknowledge).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview coalesces preparation and safely ignores disposed completion',
    (tester) async {
      final pending = Completer<RecoveryPlan>();
      var prepares = 0;
      var executes = 0;
      await tester.pumpWidget(
        _app(
          BackupPreviewScreen(
            inspector: _Inspector(),
            pickPath: () async => '/qa/backup.json',
            prepareRestore: (source, preview) {
              prepares++;
              expect(source.path, '/qa/backup.json');
              expect(preview, same(_preview));
              return pending.future;
            },
            executeRestore: (_) async => executes++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup-preview-select')));
      await tester.pumpAndSettle();
      final review = find.byKey(const ValueKey('backup-restore-review'));
      await tester.ensureVisible(review);
      await tester.pumpAndSettle();
      final activate = tester.widget<FilledButton>(review).onPressed!;
      activate();
      activate();
      await tester.pump();
      expect(prepares, 1);
      expect(tester.widget<FilledButton>(review).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      pending.completeError(StateError('private exception /secret/api-key'));
      await tester.pumpAndSettle();
      expect(executes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preparation failure is safe, actionable and can be retried', (
    tester,
  ) async {
    var prepares = 0;
    final l10n = AppLocalizations(const Locale('en'));
    await tester.pumpWidget(
      _app(
        BackupPreviewScreen(
          inspector: _Inspector(),
          pickPath: () async => '/qa/backup.json',
          prepareRestore: (_, _) async {
            prepares++;
            throw StateError('secret-api-key /private/data');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-preview-select')));
    await tester.pumpAndSettle();
    final review = find.byKey(const ValueKey('backup-restore-review'));
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.ensureVisible(review);
      await tester.pumpAndSettle();
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(find.text(l10n.get('backupRestorePrepareFailed')), findsOneWidget);
      expect(find.textContaining('secret-api-key'), findsNothing);
      expect(find.textContaining('/private/data'), findsNothing);
      expect(tester.widget<FilledButton>(review).onPressed, isNotNull);
    }
    expect(prepares, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changed source requires a new preview before confirmation', (
    tester,
  ) async {
    final l10n = AppLocalizations(const Locale('en'));
    await tester.pumpWidget(
      _app(
        BackupPreviewScreen(
          inspector: _Inspector(),
          pickPath: () async => '/qa/backup.json',
          prepareRestore: (_, _) async => throw const BackupInspectionException(
            BackupInspectionError.sourceChanged,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-preview-select')));
    await tester.pumpAndSettle();
    final review = find.byKey(const ValueKey('backup-restore-review'));
    await tester.ensureVisible(review);
    await tester.pumpAndSettle();
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(find.text(l10n.get('backupRestoreChanged')), findsOneWidget);
    expect(review, findsNothing);
    expect(find.byType(RecoveryConfirmationDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'four outcomes are distinct and blocked recovery cannot continue',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const phases = {
        RecoveryPhase.succeeded: 'backupRestoreSucceededTitle',
        RecoveryPhase.rolledBack: 'backupRestoreRolledBackTitle',
        RecoveryPhase.notApplied: 'backupRestoreNotAppliedTitle',
        RecoveryPhase.blocked: 'backupRestoreBlockedTitle',
      };
      for (final width in [375.0, 768.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 812);
        for (final language in ['zh', 'en', 'ja']) {
          for (final entry in phases.entries) {
            var continued = 0;
            var exited = 0;
            final l10n = AppLocalizations(Locale(language));
            await tester.pumpWidget(
              _app(
                RecoveryOutcomeScreen(
                  phase: entry.key,
                  rollbackDirectory: _rollback,
                  onContinue: () => continued++,
                  onExit: () => exited++,
                ),
                language: language,
                scale: 1.3,
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(l10n.get(entry.value)), findsOneWidget);
            expect(find.text(_rollback), findsOneWidget);
            final blocked = entry.key == RecoveryPhase.blocked;
            expect(
              find.byKey(const ValueKey('recovery-outcome-continue')),
              blocked ? findsNothing : findsOneWidget,
            );
            final action = find.byType(FilledButton);
            await tester.ensureVisible(action);
            await tester.pumpAndSettle();
            await tester.tap(action);
            expect(continued, blocked ? 0 : 1);
            expect(exited, blocked ? 1 : 0);
            expect(
              tester.takeException(),
              isNull,
              reason: '$width / $language / ${entry.key.name}',
            );
            await tester.pumpWidget(const SizedBox());
          }
        }
      }
    },
  );

  testWidgets('progress prevents navigation and offers no completion action', (
    tester,
  ) async {
    for (final phase in [
      RecoveryPhase.quiescing,
      RecoveryPhase.restoring,
      RecoveryPhase.reloading,
    ]) {
      await tester.pumpWidget(
        _app(
          RecoveryOutcomeScreen(
            phase: phase,
            rollbackDirectory: null,
            onContinue: () => fail('Recovery is still in progress'),
            onExit: () => fail('Recovery is still in progress'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
