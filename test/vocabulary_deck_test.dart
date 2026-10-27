import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/vocabulary_entry.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/vocabulary_deck.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'support/interaction_preview.dart';

const entry = VocabularyEntry(
  word: 'resilience',
  ipa: '/rɪˈzɪliəns/',
  partOfSpeech: 'noun · 名词',
  meaning: '适应力；恢复力',
  usage: 'build resilience · 培养适应力',
  example: 'Regular practice builds resilience.',
  translation: '经常练习可以培养适应力。',
);
final content = '${entry.toNotes()}\n\nrecall — 回想；记起\nTry to recall the word.';

void main() {
  setUpAll(loadInteractionPreviewFonts);
  test('structured and legacy notes round trip; partial edits stay intact', () {
    final words = VocabularyEntry.parseNotes(content.replaceAll('\n', '\r\n'));
    expect(words, hasLength(2));
    expect(words.first.toNotes(), entry.toNotes());
    expect(words.last.word, 'recall');
    expect(words.last.ipa, isNull);
    for (final text in [
      '$content\n\nMy own note',
      content.replaceFirst('POS:', '词性:'),
      'x' * 24001,
      content.replaceFirst('/rɪˈzɪliəns/', 'unknown'),
    ]) {
      expect(VocabularyEntry.parseNotes(text), isEmpty);
    }
  });
  test(
    'new model entries require every professional field and IPA delimiters',
    () {
      final raw = {
        'word': entry.word,
        'ipa': entry.ipa,
        'part_of_speech': entry.partOfSpeech,
        'meaning': entry.meaning,
        'usage': entry.usage,
        'example': entry.example,
        'translation': entry.translation,
      };
      for (final key in raw.keys) {
        expect(
          () => VocabularyEntry.fromModel({...raw}..remove(key)),
          throwsFormatException,
        );
      }
      expect(VocabularyEntry.fromModel(raw).toNotes(), entry.toNotes());
      expect(
        () => VocabularyEntry.fromModel({...raw, 'ipa': 'made up'}),
        throwsFormatException,
      );
      expect(
        VocabularyEntry.fromModel({...raw, 'meaning': 'two\nlines'}).meaning,
        'two lines',
      );
    },
  );

  Widget app({
    String notes = '',
    bool practice = true,
    String language = 'zh',
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) => MaterialApp(
    locale: Locale(language),
    supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
    localizationsDelegates: const [
      AppLocalizationsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: InlineFeedback(child: child!),
    ),
    home: RepaintBoundary(
      key: interactionPreviewKey,
      child: Scaffold(
        appBar: AppBar(
          title: Text(AppLocalizations(Locale(language)).get('vocabCards')),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: VocabularyDeck(
            content: notes.isEmpty ? content : notes,
            practice: practice,
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'word navigation hides answers and editing resets the current card',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('resilience'), findsOneWidget);
      expect(find.text(entry.meaning), findsNothing);
      await tester.tap(find.byKey(const ValueKey('vocab-reveal')));
      await tester.pump();
      expect(find.text(entry.meaning), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('vocab-next')));
      await tester.tap(find.byKey(const ValueKey('vocab-next')));
      await tester.pump();
      expect(find.text('recall'), findsOneWidget);
      expect(find.text('回想；记起'), findsNothing);
      await tester.pumpWidget(app(notes: entry.toNotes()));
      await tester.pump();
      expect(find.text('resilience'), findsOneWidget);
      expect(find.text('1 / 1'), findsOneWidget);
      final custom = '$content\n\nPersonal note stays here.';
      await tester.pumpWidget(app(notes: custom));
      expect(find.text(custom), findsOneWidget);
    },
  );

  for (final language in ['zh', 'en', 'ja']) {
    for (final brightness in Brightness.values) {
      testWidgets('cards $language $brightness fit 320 width and double font', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          app(
            language: language,
            brightness: brightness,
            scale: 2,
            practice: false,
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('vocab-next')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('vocab-next')));
        await tester.pump();
        expect(find.text('recall'), findsOneWidget);
      });
    }
  }

  testWidgets('capture light and dark learning card previews', (tester) async {
    tester.view.physicalSize = const Size(430, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(app(brightness: brightness, practice: false));
      await tester.pumpAndSettle();
      await captureInteractionPreview(tester, 'vocabulary-${brightness.name}');
      expect(tester.takeException(), isNull);
    }
  });
}
