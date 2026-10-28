import '../models/reminder.dart';
import 'quick_reminder_parser.dart';

/// Automatic application uses grounded intent and independently readable times.
/// Model-suggested preparation time remains a suggestion, not a new alarm.
class CaptureAutomationPolicy {
  static bool needsReview(String text) => QuickReminderParser.isAmbiguous(text);
  static bool _grounded(String title, String source) {
    final tokens = RegExp(
      r'[a-z0-9]+|[^\x00-\x7f\s，。！？：；、（）“”‘’]',
      caseSensitive: false,
    );
    final wanted = tokens
        .allMatches(title.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    final actual = tokens
        .allMatches(source.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    if (wanted.isEmpty) return false;
    var index = 0;
    for (final token in actual) {
      if (token == wanted[index] && ++index == wanted.length) return true;
    }
    return false;
  }

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.difference(b).inMicroseconds.abs() < Duration.microsecondsPerMinute;

  static DateTime? _explicit(String source, DateTime reference, Reminder item) {
    if (!item.isRecurring) {
      return QuickReminderParser.parse(source, now: reference);
    }
    final rule = item.recurrenceRule;
    final cadence = switch (rule) {
      'daily' => RegExp(r'每天|每日|毎日|\bdaily\b|every day', caseSensitive: false),
      'workday' => RegExp(
        r'工作日|平日|\bweekdays\b|every workday',
        caseSensitive: false,
      ),
      'weekly' => RegExp(
        r'每周|每星期|毎週|every (?:mon|tues|wednes|thurs|fri|satur|sun)day',
        caseSensitive: false,
      ),
      _ => null,
    };
    if (cadence == null || !cadence.hasMatch(source)) return null;
    return QuickReminderParser.parse(source, now: reference);
  }

  static List<Reminder>? resolve(
    Reminder baseline,
    List<Reminder> candidates, {
    required DateTime now,
    bool imageSource = false,
  }) {
    final source = baseline.sourceText?.trim() ?? '';
    if (source.isEmpty ||
        candidates.isEmpty ||
        candidates.length > 8 ||
        source.length > 4000 ||
        baseline.details.kind != 'task' ||
        baseline.details.paused ||
        baseline.details.hidden ||
        baseline.details.planId != null ||
        baseline.reviewNotificationsEnabled ||
        baseline.wordProgressJson != null ||
        baseline.contextTrigger != null ||
        baseline.isCompleted) {
      return null;
    }
    if (baseline.recordId == null &&
        (baseline.taskTitle != String.fromCharCodes(source.runes.take(80)) ||
            baseline.details.history.any((e) => e.action == 'edited'))) {
      return null;
    }
    var chunks = source
        .split(RegExp(r'[\n;；。]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (imageSource) {
      if (candidates.any(
        (e) =>
            e.details.data['capture_requires_review'] != false ||
            e.details.data['capture_evidence'] is! String,
      )) {
        return null;
      }
      chunks = candidates
          .map((e) => (e.details.data['capture_evidence'] as String).trim())
          .toList();
    }
    if (chunks.length != candidates.length ||
        chunks.any((e) => e.isEmpty || e.length > 500 || needsReview(e))) {
      return null;
    }
    final remaining = [...candidates], result = <Reminder>[];
    final reference = baseline.createdAt ?? now;
    for (var i = 0; i < chunks.length; i++) {
      final text = chunks[i];
      final matches = remaining
          .where((e) => _grounded(e.taskTitle, text))
          .toList();
      if (matches.length != 1) return null;
      final item = matches.single, metadata = matches.single.details.data;
      if (item.taskTitle.trim().isEmpty ||
          item.taskTitle.length > 160 ||
          item.quadrantLevel < 1 ||
          item.quadrantLevel > 4 ||
          item.isCompleted ||
          item.details.kind != 'task' ||
          item.details.repeat != null ||
          item.details.checklist.isNotEmpty ||
          item.subTasks?.isNotEmpty == true ||
          item.contextTrigger != null ||
          item.reviewNotificationsEnabled ||
          item.wordProgressJson != null ||
          item.linkedTaskIds.isNotEmpty ||
          (metadata.containsKey('capture_requires_review') &&
              metadata['capture_requires_review'] != false) ||
          (metadata['capture_issues'] != null &&
              (metadata['capture_issues'] is! List ||
                  (metadata['capture_issues'] as List).isNotEmpty))) {
        return null;
      }
      final explicit = _explicit(text, reference, item);
      if (!item.isRecurring &&
          RegExp(
            r'每天|每日|毎日|每周|每星期|毎週|每月|每年|工作日|平日|\b(?:daily|weekly|monthly|yearly|weekdays)\b|every\s+',
            caseSensitive: false,
          ).hasMatch(text)) {
        return null;
      }
      if (item.isRecurring && explicit == null) return null;
      if (item.eventTime != null &&
          (explicit == null || !_sameMinute(item.eventTime!, explicit))) {
        return null;
      }
      if (item.eventTime == null && item.triggerTime != null) return null;
      if (i == 0 &&
          baseline.eventTime != null &&
          (explicit == null || !_sameMinute(baseline.eventTime!, explicit))) {
        return null;
      }
      final event = i == 0 ? baseline.eventTime ?? explicit : explicit;
      final trigger = i == 0 ? baseline.triggerTime ?? event : event;
      if (trigger != null && !trigger.isAfter(now)) return null;
      final suggested = item.triggerTime;
      result.add(
        item.copyWith(
          taskSummary: text,
          eventTime: event,
          triggerTime: trigger,
          timeOrigin: i == 0 && baseline.triggerTime != null
              ? baseline.timeOrigin
              : trigger == null
              ? ReminderTimeOrigin.unknown
              : ReminderTimeOrigin.manual,
          suggestedTriggerTime:
              suggested != null &&
                  suggested.isAfter(now) &&
                  suggested != trigger
              ? suggested
              : null,
        ),
      );
      remaining.remove(item);
    }
    return result;
  }
}
