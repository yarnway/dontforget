import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/review_report.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/task_statistics_provider.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/ui/screens/dashboard_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Source extends RemindersNotifier {
  _Source(super.database) : super(runLoadEffects: false);
  void replace(List<Reminder> tasks) => state = tasks;
}

class _Reviews implements LLMService {
  Completer<ReviewReport>? pending;
  int calls = 0;
  @override
  Future<ReviewReport> generateReview(
    List<Reminder> tasks,
    AppSettings settings, {
    String language = 'zh',
  }) {
    calls++;
    return pending!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Source source;
  late _Reviews reviews;
  final tasks = List.generate(
    20,
    (i) => Reminder(
      id: '$i',
      taskTitle: 'Task $i',
      quadrantLevel: i % 4 + 1,
      isCompleted: i % 3 == 0,
    ),
  );
  const sourceKey = ValueKey('review-source');
  const generateKey = ValueKey('review-generate');
  const copyKey = ValueKey('review-copy');
  const previewKey = ValueKey('dashboard-preview');

  setUpAll(() async {
    if (const bool.fromEnvironment('UI_PREVIEW')) {
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
  });
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dashboard-test-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    source = _Source(database);
    await source.ready;
    source.replace(tasks);
    reviews = _Reviews();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        remindersProvider.overrideWith((_) => source),
        llmServiceProvider.overrideWithValue(reviews),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  Future<void> show(
    WidgetTester tester, {
    double width = 1440,
    double scale = 1,
    String language = 'en',
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: previewKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF7A8B8B),
                brightness: brightness,
              ),
            ),
            locale: Locale(language),
            supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: InlineFeedback(child: child!),
            ),
            home: const DashboardScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> generate(WidgetTester tester) async {
    reviews.pending = Completer<ReviewReport>();
    await tester.scrollUntilVisible(
      find.byKey(generateKey).hitTestable(),
      250,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    await tester.tap(find.byKey(generateKey));
    await tester.pump();
  }

  testWidgets(
    'statistics stay cached through report states; failure, retry and stale snapshot are visible',
    (tester) async {
      await show(tester);
      final stats = container.read(taskStatisticsProvider);
      expect(stats.total, 20);
      await generate(tester);
      expect(container.read(taskStatisticsProvider), same(stats));
      expect(
        tester.widget<FilledButton>(find.byKey(generateKey)).onPressed,
        isNull,
      );
      expect(reviews.calls, 1);
      reviews.pending!.completeError(StateError('SECRET must not reach UI'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not generate the report. Please try again. Your previous report is kept.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('SECRET'), findsNothing);
      await generate(tester);
      source.replace([
        ...tasks,
        Reminder(
          id: 'extra',
          taskTitle: 'Added while loading',
          quadrantLevel: 2,
        ),
      ]);
      reviews.pending!.complete(
        const ReviewReport(
          'Report snapshot',
          source: ReviewReportSource.localAfterFailure,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(sourceKey), findsOneWidget);
      expect(find.text('Local statistics report'), findsOneWidget);
      expect(find.textContaining('The model did not return'), findsOneWidget);
      expect(
        find.textContaining('Tasks or settings have changed'),
        findsOneWidget,
      );
      final nextStats = container.read(taskStatisticsProvider);
      expect(nextStats.total, 21);
      await generate(tester);
      expect(find.text('Report snapshot'), findsOneWidget);
      reviews.pending!.completeError(StateError('another failure'));
      await tester.pumpAndSettle();
      expect(find.text('Report snapshot'), findsOneWidget);
      await generate(tester);
      reviews.pending!.complete(
        const ReviewReport(
          'Fresh model report',
          source: ReviewReportSource.model,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('AI model report'), findsOneWidget);
      expect(
        find.textContaining('Tasks or settings have changed'),
        findsNothing,
      );
      expect(find.textContaining('The model did not return'), findsNothing);
      expect(container.read(taskStatisticsProvider), same(nextStats));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'copy awaits platform completion and reports failure without false success',
    (tester) async {
      await show(tester);
      await generate(tester);
      reviews.pending!.complete(
        const ReviewReport('Local fixture', source: ReviewReportSource.local),
      );
      await tester.pumpAndSettle();
      var clipboard = Completer<void>();
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
              await clipboard.future;
            }
            return null;
          });
      await tester.scrollUntilVisible(
        find.byKey(copyKey).hitTestable(),
        250,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
      await tester.tap(find.byKey(copyKey));
      await tester.pump();
      expect(
        find.text('Productivity report copied to clipboard'),
        findsNothing,
      );
      expect(
        tester.widget<OutlinedButton>(find.byKey(copyKey)).onPressed,
        isNull,
      );
      clipboard.completeError(PlatformException(code: 'clipboard_denied'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not copy the report. Please try again.'),
        findsOneWidget,
      );
      expect(
        find.text('Productivity report copied to clipboard'),
        findsNothing,
      );
      clipboard = Completer<void>();
      await tester.tap(find.byKey(copyKey));
      await tester.pump();
      clipboard.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Productivity report copied to clipboard'),
        findsOneWidget,
      );
      expect(copied, 'Local statistics report\n\nLocal fixture');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('empty workspace is scrollable and does not offer generation', (
    tester,
  ) async {
    source.replace([]);
    await show(tester, width: 375, scale: 2);
    expect(find.byKey(generateKey), findsNothing);
    expect(
      find.text('No tasks yet. Create some to see statistics!'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('dashboard layout $width ${brightness.name}', (tester) async {
        await show(tester, width: width, brightness: brightness);
        expect(tester.takeException(), isNull);
        expect(tester.binding.transientCallbackCount, 0);
        if (const bool.fromEnvironment('UI_PREVIEW')) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(previewKey),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('dist/dashboard-preview').create(recursive: true);
            await File(
              'dist/dashboard-preview/dashboard-${width.toInt()}-${brightness.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  for (final language in ['en', 'zh', 'ja']) {
    testWidgets(
      'large-text report, controls and counts fit a phone in $language',
      (tester) async {
        source.replace(
          List.generate(
            10000,
            (i) => Reminder(
              id: '$i',
              taskTitle: 'Task $i',
              quadrantLevel: i % 4 + 1,
            ),
          ),
        );
        await show(tester, width: 375, scale: 2, language: language);
        expect(tester.takeException(), isNull);
        await generate(tester);
        reviews.pending!.complete(
          const ReviewReport(
            'A report with enough text to wrap across narrow displays.',
            source: ReviewReportSource.localAfterFailure,
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(copyKey).hitTestable(),
          250,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 30,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
