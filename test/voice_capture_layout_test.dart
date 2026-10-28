import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/ui/widgets/voice_capture_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    Size size, {
    String language = 'zh',
    double scale = 1,
    VoiceReleaseAction action = VoiceReleaseAction.save,
    bool preparing = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: EdgeInsets.only(top: size.height >= 568 ? 59 : 0),
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: SizedBox.expand(
            child: VoiceCaptureFeedback(
              action: action,
              fullScreen: true,
              preparing: preparing,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Rect rect(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey(key)));

  setUp(() {
    addTearDown(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  testWidgets('a taller phone keeps the release caption near the action arcs', (
    tester,
  ) async {
    for (final width in [375.0, 430.0]) {
      double? previousGap;
      Rect? previousBubble;
      double? previousHeight;
      for (final height in [667.0, 932.0, 1232.0]) {
        await show(tester, Size(width, height));
        final caption = rect(tester, 'voice-release-caption');
        final cancel = rect(tester, 'voice-target-cancel');
        final bubble = rect(tester, 'voice-recording-bubble');
        final gap = cancel.top - caption.bottom;
        expect(gap, inInclusiveRange(24, 80));
        expect(bubble.bottom, lessThan(caption.top));
        expect(bubble.center.dx, closeTo(width / 2, .5));
        expect(caption.center.dx, closeTo(width / 2, .5));
        if (previousGap != null) {
          expect(gap, closeTo(previousGap, .5));
          expect(
            bubble.top - previousBubble!.top,
            closeTo(height - previousHeight!, .5),
          );
        }
        previousGap = gap;
        previousBubble = bubble;
        previousHeight = height;
      }
    }
  });

  testWidgets(
    'recording feedback stays above the arcs across text and screens',
    (tester) async {
      for (final size in [
        const Size(320, 568),
        const Size(375, 812),
        const Size(430, 932),
        const Size(568, 320),
        const Size(1440, 900),
      ]) {
        for (final language in ['zh', 'en', 'ja']) {
          for (final scale in [1.0, 2.0]) {
            await show(tester, size, language: language, scale: scale);
            final feedback = rect(tester, 'voice-recording-feedback');
            final bubble = rect(tester, 'voice-recording-bubble');
            final caption = rect(tester, 'voice-release-caption');
            expect(feedback.top, greaterThanOrEqualTo(8));
            expect(feedback.left, greaterThanOrEqualTo(0));
            expect(feedback.right, lessThanOrEqualTo(size.width));
            expect(feedback.contains(bubble.center), isTrue);
            expect(feedback.contains(caption.center), isTrue);
            for (final action in ['cancel', 'text']) {
              final target = rect(tester, 'voice-target-$action');
              expect(
                feedback.bottom,
                lessThan(target.top - 8),
                reason: '$size / $language / $scale / $action',
              );
              expect(target.bottom, lessThan(size.height));
            }
          }
        }
      }
    },
  );

  testWidgets('sliding and preparing do not shift the feedback group', (
    tester,
  ) async {
    for (final language in ['zh', 'en', 'ja']) {
      for (final size in [const Size(320, 568), const Size(568, 320)]) {
        Rect? bubble;
        Rect? feedback;
        for (final action in VoiceReleaseAction.values) {
          for (final preparing in [false, true]) {
            await show(
              tester,
              size,
              language: language,
              scale: 2,
              action: action,
              preparing: preparing,
            );
            final nextBubble = rect(tester, 'voice-recording-bubble');
            final nextFeedback = rect(tester, 'voice-recording-feedback');
            if (bubble != null) {
              expect(nextBubble, bubble);
              expect(nextFeedback, feedback);
            }
            bubble = nextBubble;
            feedback = nextFeedback;
          }
        }
      }
    }
  });
}
