import 'dart:async';

import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  final settings = <InitializationSettings>[];
  final successfulRegistrations = <Set<String>>[];
  final pending = <int, NotificationDetails>{};
  final unregisteredCategories = <String>[];
  final firstInitializationStarted = Completer<void>();
  Completer<void>? firstInitializationGate;
  int? failInitializationNumber;

  Future<bool> _initialize(InitializationSettings configuration) async {
    settings.add(configuration);
    final number = settings.length;
    if (number == 1) {
      firstInitializationStarted.complete();
      await firstInitializationGate?.future;
    }
    if (number == failInitializationNumber) {
      throw PlatformException(code: 'synthetic_category_registration_failure');
    }
    successfulRegistrations.add({
      for (final options in [configuration.iOS!, configuration.macOS!])
        for (final category in options.notificationCategories)
          category.identifier,
    });
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        return _initialize(
          call.positionalArguments.single as InitializationSettings,
        );
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value();
      case #cancel:
        pending.remove(call.positionalArguments.first as int);
        return Future<void>.value();
      case #cancelAll:
        pending.clear();
        return Future<void>.value();
      case #zonedSchedule:
        final details = call.positionalArguments[4] as NotificationDetails;
        for (final identifier in [
          details.iOS!.categoryIdentifier!,
          details.macOS!.categoryIdentifier!,
        ]) {
          if (!successfulRegistrations.last.contains(identifier)) {
            unregisteredCategories.add(identifier);
          }
        }
        pending[call.positionalArguments.first as int] = details;
        return Future<void>.value();
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Native native;
  late NotificationService service;
  final now = DateTime.utc(2026, 10, 28, 12);

  Reminder task(String id) => Reminder(
    id: id,
    taskTitle: 'Synthetic language reconciliation',
    quadrantLevel: 2,
    triggerTime: now.add(const Duration(hours: 1)),
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    native = _Native();
    service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      nativePendingLimit: 4,
      now: () => now,
    );
  });

  tearDown(() async {
    await service.pauseForMaintenance();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'changing language during blocked initialization registers the final categories before scheduling',
    () async {
      native.firstInitializationGate = Completer<void>();
      final initializing = service.init();
      await native.firstInitializationStarted.future;
      final languageChange = service.setNotificationLanguage('zh');
      await Future<void>.delayed(Duration.zero);
      expect(native.settings, hasLength(1));
      expect(
        native.settings.first.iOS!.notificationCategories.first.identifier,
        endsWith('_en'),
      );
      native.firstInitializationGate!.complete();
      await Future.wait([initializing, languageChange]);
      expect(native.settings, hasLength(2));
      expect(native.successfulRegistrations.last, {
        'dontforget_ios_once_zh',
        'dontforget_ios_recurring_zh',
        'dontforget_macos_once_zh',
        'dontforget_macos_recurring_zh',
      });
      await service.scheduleReminderStrict(task('after-initialization'));
      expect(
        native.pending.values.single.iOS!.categoryIdentifier,
        'dontforget_ios_once_zh',
      );
      expect(native.unregisteredCategories, isEmpty);
    },
  );

  test(
    'failed category re-registration can retry the same language and reconcile tasks added during failure',
    () async {
      await service.scheduleReminderStrict(task('before-language-change'));
      expect(
        native.pending.values.single.iOS!.categoryIdentifier,
        'dontforget_ios_once_en',
      );
      native.failInitializationNumber = 2;
      await expectLater(
        service.setNotificationLanguage('ja'),
        throwsA(isA<PlatformException>()),
      );
      expect(native.settings, hasLength(2));
      expect(native.successfulRegistrations, hasLength(1));

      // A newly saved reminder must reference the last successful categories,
      // and must also be re-submitted when the requested language later succeeds.
      await service.scheduleReminderStrict(task('during-registration-failure'));
      expect(native.pending, hasLength(2));
      expect(
        native.pending.values.every(
          (details) =>
              details.iOS!.categoryIdentifier == 'dontforget_ios_once_en',
        ),
        isTrue,
      );
      expect(native.unregisteredCategories, isEmpty);

      await service.setNotificationLanguage('ja');
      expect(native.settings, hasLength(3));
      expect(native.successfulRegistrations, hasLength(2));
      expect(
        native.pending.values.every(
          (details) =>
              details.iOS!.categoryIdentifier == 'dontforget_ios_once_ja',
        ),
        isTrue,
      );
      expect(native.unregisteredCategories, isEmpty);
      await service.setNotificationLanguage('ja');
      expect(native.settings, hasLength(3));
    },
  );
}
