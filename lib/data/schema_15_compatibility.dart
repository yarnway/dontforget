import 'schema_14_compatibility.dart';

/// Two independent development branches used v15. Version 16 is their union.
enum Schema15Shape { recordReminder, taskManagement }

const schema15SettingsColumns = {
  ...schema13SettingsColumns,
  ...schema14CaptureSettingsColumns,
};

const schema15CommonReminderColumns = {
  ...schema13ReminderColumns,
  ...schema14CaptureReminderColumns,
  'capture_proposal_json',
  'word_progress_json',
};

Schema15Shape? identifySchema15({
  required Set<String> settingsColumns,
  required Set<String> reminderColumns,
}) {
  bool same(Set<String> actual, Set<String> expected) =>
      actual.length == expected.length && actual.containsAll(expected);
  if (!same(settingsColumns, schema15SettingsColumns)) return null;
  if (same(reminderColumns, {
    ...schema15CommonReminderColumns,
    'trigger_time_origin',
  })) {
    return Schema15Shape.recordReminder;
  }
  if (same(reminderColumns, {
    ...schema15CommonReminderColumns,
    'details_json',
  })) {
    return Schema15Shape.taskManagement;
  }
  return null;
}

List<String> schema15UpgradeStatements(Schema15Shape shape) => [
  if (shape == Schema15Shape.recordReminder)
    'ALTER TABLE Reminders ADD COLUMN details_json TEXT',
  if (shape == Schema15Shape.taskManagement)
    "ALTER TABLE Reminders ADD COLUMN trigger_time_origin TEXT NOT NULL DEFAULT 'unknown'",
];
