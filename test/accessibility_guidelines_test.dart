import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/shared_text_provider.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:dont_forget/services/shared_text_inbox.dart';
import 'package:dont_forget/services/voice_text_draft.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:dont_forget/ui/screens/shared_text_inbox_screen.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:dont_forget/ui/widgets/lan_sync_conflicts_dialog.dart';
import 'package:dont_forget/ui/widgets/live_voice_text_dialog.dart';
import 'package:dont_forget/ui/widgets/portable_backup_panel.dart';
import 'package:dont_forget/ui/widgets/voice_capture_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/offline_management_harness.dart';
import 'support/real_io.dart';
import 'support/workspace_drafts.dart';

class _StubRecorder implements AudioRecorder {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _A11yHomeController extends HomeController {
  _A11yHomeController(super.ref) : super(audioRecorder: _StubRecorder());
  int starts = 0, cancels = 0, saves = 0;

  @override
  Future<bool> startRecording() async {
    starts++;
    state = HomeState(isRecording: true);
    return true;
  }

  @override
  void prepareRecordingTranscription() {
    state = state.copyWith(voicePreview: '语音无障碍测试');
  }

  @override
  VoiceTextDraft createVoiceTextDraft() => VoiceTextDraft(
    result: stopRecordingToText(),
    saveOriginal: () async {
      await stopRecordingAndProcess();
      return true;
    },
    releaseCapture: (_) async {},
  );

  @override
  Future<String?> stopRecordingToText({bool Function()? canAcceptDraft}) async {
    state = state.copyWith(isRecording: false);
    return '语音无障碍测试';
  }

  @override
  Future<void> stopRecordingAndProcess() async {
    saves++;
    state = state.copyWith(isRecording: false);
  }

  @override
  Future<bool> cancelRecording() async {
    cancels++;
    state = HomeState();
    return true;
  }
}

Widget _shell(
  Widget child, {
  ProviderContainer? container,
  TargetPlatform platform = TargetPlatform.android,
  bool accessibleNavigation = false,
  double textScale = 1.0,
  ThemeData? theme,
}) {
  final app = MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
    localizationsDelegates: const [
      AppLocalizationsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: (theme ?? AppTheme.light).copyWith(platform: platform),
    builder: (context, inner) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        accessibleNavigation: accessibleNavigation,
        textScaler: TextScaler.linear(textScale),
      ),
      child: InlineFeedback(child: inner!),
    ),
    home: child,
  );
  return container == null
      ? ProviderScope(child: app)
      : UncontrolledProviderScope(container: container, child: app);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets(
    'TalkBack/VoiceOver accessible navigation enables single-tap voice capture and interactive controls',
    (tester) async {
      final harness = OfflineManagementHarness();
      await tester.runAsync(harness.create);
      late _A11yHomeController controller;
      final container = ProviderContainer(
        overrides: [
          databaseHelperProvider.overrideWithValue(harness.database),
          notificationServiceProvider.overrideWithValue(harness.notifications),
          homeControllerProvider.overrideWith((ref) {
            controller = _A11yHomeController(ref);
            return controller;
          }),
        ],
      );
      await tester.runAsync(() async {
        await container.read(settingsProvider.notifier).ready;
        await container.read(workspaceDraftsProvider.notifier).ready;
      });
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _shell(
            const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: InputBottomBar(),
              ),
            ),
            container: container,
            platform: TargetPlatform.android,
            accessibleNavigation: true,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Switch composer to voice mode.
        await tester.tap(find.byKey(const ValueKey('composer-mode-toggle')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(const ValueKey('composer-voice-pad')),
          findsOneWidget,
        );

        // Single tap on voice pad under accessibleNavigation starts recording.
        await tester.tap(find.byKey(const ValueKey('composer-voice-pad')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.starts, 1);
        expect(
          find.byKey(const ValueKey('voice-accessible-actions')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('voice-accessible-save')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('voice-accessible-text')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('voice-accessible-cancel')),
          findsOneWidget,
        );

        // Verify accessible action buttons meet 48dp Android tap target.
        for (final key in const [
          ValueKey('voice-accessible-save'),
          ValueKey('voice-accessible-text'),
          ValueKey('voice-accessible-cancel'),
        ]) {
          final size = tester.getSize(find.byKey(key));
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }

        // Cancel via accessible button cleanly cancels recording.
        await tester.tap(find.byKey(const ValueKey('voice-accessible-cancel')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.cancels, 1);
        expect(
          find.byKey(const ValueKey('voice-accessible-actions')),
          findsNothing,
        );

        // Tap again and save voice memo via accessible Save button.
        await tester.tap(find.byKey(const ValueKey('composer-voice-pad')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.starts, 2);
        await tester.tap(find.byKey(const ValueKey('voice-accessible-save')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.saves, 1);
        expect(
          find.byKey(const ValueKey('voice-accessible-actions')),
          findsNothing,
        );
        await drainWorkspaceDrafts(tester, container);
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.runAsync(harness.dispose);
      }
    },
  );

  testWidgets(
    'PortableBackupPanel password toggles expose localized tooltips and satisfy labeled tap target guideline',
    (tester) async {
      final harness = OfflineManagementHarness();
      await tester.runAsync(harness.create);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _shell(
            const Scaffold(body: PortableBackupPanel()),
            container: harness.container,
            platform: TargetPlatform.android,
          ),
        );
        await pumpUntilRealIo(
          tester,
          () => find
              .byKey(const ValueKey('backup-password-toggle'))
              .evaluate()
              .isNotEmpty,
          reason: 'PortableBackupPanel should render password toggle',
        );

        final toggle = tester.widget<IconButton>(
          find.byKey(const ValueKey('backup-password-toggle')),
        );
        final repeatToggle = tester.widget<IconButton>(
          find.byKey(const ValueKey('backup-password-repeat-toggle')),
        );
        expect(toggle.tooltip, '显示密码');
        expect(repeatToggle.tooltip, '显示密码');

        await tester.tap(find.byKey(const ValueKey('backup-password-toggle')));
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('backup-password-toggle')),
              )
              .tooltip,
          '隐藏密码',
        );

        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      }
    },
  );

  testWidgets(
    'SharedTextInboxScreen and share editor label controls and meet tap target guidelines',
    (tester) async {
      final harness = OfflineManagementHarness();
      await tester.runAsync(harness.create);
      const item = SharedText(
        id: '00000000-0000-4000-8000-000000000088',
        text: '测试分享文案',
        createdAt: 1762300800000,
      );
      await tester.runAsync(
        () => harness.container.read(sharedTextInboxProvider).accept(item),
      );
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _shell(
            const SharedTextInboxScreen(),
            container: harness.container,
            platform: TargetPlatform.android,
          ),
        );
        await pumpUntilRealIo(
          tester,
          () => find
              .byKey(
                const ValueKey(
                  'shared-item-00000000-0000-4000-8000-000000000088',
                ),
              )
              .evaluate()
              .isNotEmpty,
          reason: 'SharedTextInboxScreen should render seeded draft item',
        );

        await tester.tap(
          find.byKey(
            const ValueKey('shared-item-00000000-0000-4000-8000-000000000088'),
          ),
        );
        await pumpUntilRealIo(
          tester,
          () => find
              .byKey(const ValueKey('shared-text-editor'))
              .evaluate()
              .isNotEmpty,
          reason: 'Shared text editor should open',
        );

        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('shared-text-editor')),
        );
        expect(field.decoration?.labelText, isNotEmpty);
        expect(field.decoration?.hintText, isNotEmpty);

        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      }
    },
  );

  testWidgets(
    'SettingsScreen LAN sync switch exposes accessible label and meets labeled tap target guideline',
    (tester) async {
      final harness = OfflineManagementHarness();
      await tester.runAsync(harness.create);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _shell(
            const SettingsScreen(area: SettingsArea.sync),
            container: harness.container,
            platform: TargetPlatform.android,
          ),
        );
        await pumpUntilRealIo(
          tester,
          () => find
              .byKey(const ValueKey('lan-sync-server'))
              .evaluate()
              .isNotEmpty,
          reason: 'SettingsScreen sync area should finish loading',
        );

        final switchNode = tester.getSemantics(
          find.byKey(const ValueKey('lan-sync-server')),
        );
        expect(switchNode.label, contains('局域网同步'));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      }
    },
  );

  testWidgets(
    'TaskDetailScreen reader exposes checklist completion semantics to screen readers',
    (tester) async {
      final harness = OfflineManagementHarness();
      await tester.runAsync(harness.create);
      final task = Reminder(
        id: 'a11y-reader-task',
        taskTitle: '检查清单无障碍任务',
        quadrantLevel: 2,
        detailsJson: const TaskDetails(
          checklist: [
            ChecklistItem('c1', '已完成项', done: true),
            ChecklistItem('c2', '未完成项', done: false),
          ],
        ).encode(),
      );
      await tester.runAsync(() => harness.notifier.addReminder(task));
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _shell(
            TaskDetailScreen(task: task),
            container: harness.container,
            platform: TargetPlatform.android,
          ),
        );
        await pumpUntilRealIo(
          tester,
          () => find.text('已完成项').evaluate().isNotEmpty,
          reason: 'TaskDetailScreen reader should render checklist items',
        );

        expect(find.bySemanticsLabel(RegExp('已完成')), findsAtLeastNWidgets(1));
        expect(find.bySemanticsLabel(RegExp('未完成')), findsAtLeastNWidgets(1));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      }
    },
  );

  testWidgets(
    'LanSyncConflictsDialog handles 2.0x text scale without overflow and labels empty values',
    (tester) async {
      const conflict = LanSyncConflict(
        taskId: 'conflict-a11y-1',
        local: (title: '本机标题', note: '', inTrash: false),
        peer: (title: '对端标题', note: '对端备注', inTrash: true),
      );
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _shell(
            const Scaffold(
              body: LanSyncConflictsDialog(
                conflicts: [conflict],
                openableTaskIds: {'conflict-a11y-1'},
                adoptableTaskIds: {'conflict-a11y-1'},
                trashActionTaskIds: {'conflict-a11y-1'},
              ),
            ),
            platform: TargetPlatform.android,
            textScale: 2.0,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('本机标题'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel(RegExp('空')), findsAtLeastNWidgets(1));
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'mobile voice editor exposes the error hint to screen readers and preserves 48dp actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _shell(
            Scaffold(
              body: LiveVoiceTextDialog(
                result: Future<String?>.value(null),
                prefix: '',
                initial: '部分识别结果',
                onChanged: (_) {},
              ),
            ),
            platform: TargetPlatform.android,
            textScale: 2.0,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('识别未完成，可继续编辑。'), findsNothing);
        expect(find.text('核对文字'), findsNothing);
        expect(find.text('编辑文字'), findsNothing);
        expect(find.byKey(const ValueKey('voice-editor-keep')), findsNothing);
        final dialog = tester.widget<Dialog>(
          find.byKey(const ValueKey('voice-text-sheet')),
        );
        expect(dialog.backgroundColor, Colors.transparent);
        expect(dialog.shape, const RoundedRectangleBorder());
        final editor = find.bySemanticsLabel(RegExp('编辑文字')).first;
        expect(tester.getSemantics(editor).hint, '识别未完成，可继续编辑。');
        for (final key in ['voice-editor-original', 'voice-editor-send']) {
          final size = tester.getSize(find.byKey(ValueKey(key)));
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'InlineFeedback close button exposes localized tooltip directly and satisfies labeled tap target guideline',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        late BuildContext pageContext;
        await tester.pumpWidget(
          _shell(
            Scaffold(
              body: Builder(
                builder: (context) {
                  pageContext = context;
                  return const SizedBox.expand();
                },
              ),
            ),
            platform: TargetPlatform.android,
          ),
        );
        await tester.pump();

        InlineFeedback.of(pageContext).showSnackBar(
          const SnackBar(content: Text('请核对文字，或发送原语音。')),
          tone: FeedbackTone.warning,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final closeFinder = find.byKey(const ValueKey('inline-feedback-close'));
        expect(closeFinder, findsOneWidget);
        final closeSemantics = tester.getSemantics(closeFinder);
        expect(closeSemantics.label, contains('关闭'));

        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

        await tester.tap(closeFinder);
        await tester.pump();
        expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'VoiceCaptureFeedback accessible cancel button uses opaque dark surface for WCAG contrast on bottom arc',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _shell(
            Scaffold(
              body: VoiceCaptureFeedback(
                action: VoiceReleaseAction.save,
                fullScreen: true,
                onAccessibleAction: (_) {},
              ),
            ),
            platform: TargetPlatform.android,
            accessibleNavigation: true,
          ),
        );
        await tester.pump();

        final cancelButton = tester.widget<OutlinedButton>(
          find.byKey(const ValueKey('voice-accessible-cancel')),
        );
        final bg = cancelButton.style?.backgroundColor?.resolve(
          <WidgetState>{},
        );
        final fg = cancelButton.style?.foregroundColor?.resolve(
          <WidgetState>{},
        );
        expect(bg, const Color(0xFF2B2B2B));
        expect(fg, Colors.white);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        semantics.dispose();
      }
    },
  );
}
