/// The two independently developed v14 schemas cannot be identified by their
/// version number alone. Only these complete shapes are safe to upgrade.
enum Schema14Shape { reminderOrigin, captureFlow }

const schema13SettingsColumns = <String>{
  'id',
  'api_key',
  'base_url',
  'model_name',
  'language',
  'ai_profiles_json',
  'ai_fallback_enabled',
  'appearance',
  'input_send_mode',
};

const schema13ReminderColumns = <String>{
  'id',
  'record_id',
  'task_title',
  'task_summary',
  'quadrant_level',
  'urgency_level',
  'importance_level',
  'trigger_time',
  'is_completed',
  'is_recurring',
  'recurrence_rule',
  'recurrence_description',
  'is_emotion_filtered',
  'sub_tasks',
  'created_at',
  'review_level',
  'next_review_at',
  'review_notifications_enabled',
  'original_quadrant_level',
  'is_dynamically_promoted',
  'linked_task_ids',
  'context_trigger',
  'notice_revision',
  'notice_acknowledged_at',
  'upcoming_dismissed_at',
  'snoozed_at',
  'recurrence_anchor_time',
};

const schema14CaptureSettingsColumns = <String>{'workspace_drafts_json'};
const schema14CaptureReminderColumns = <String>{
  'event_time',
  'recurrence_event_anchor_time',
  'suggested_trigger_time',
  'source_text',
  'capture_pending',
  'is_pinned',
};
const schema14OriginReminderColumns = <String>{'trigger_time_origin'};

bool _sameColumns(Set<String> actual, Set<String> expected) =>
    actual.length == expected.length && actual.containsAll(expected);

/// A JSON snapshot always has a settings row even if it has no reminders.
Schema14Shape? identifySchema14FromSettings(Set<String> columns) {
  if (_sameColumns(columns, schema13SettingsColumns)) {
    return Schema14Shape.reminderOrigin;
  }
  if (_sameColumns(columns, {
    ...schema13SettingsColumns,
    ...schema14CaptureSettingsColumns,
  })) {
    return Schema14Shape.captureFlow;
  }
  return null;
}

Schema14Shape? identifySchema14({
  required Set<String> settingsColumns,
  required Set<String> reminderColumns,
}) {
  if (_sameColumns(settingsColumns, schema13SettingsColumns) &&
      _sameColumns(reminderColumns, {
        ...schema13ReminderColumns,
        ...schema14OriginReminderColumns,
      })) {
    return Schema14Shape.reminderOrigin;
  }
  if (_sameColumns(settingsColumns, {
        ...schema13SettingsColumns,
        ...schema14CaptureSettingsColumns,
      }) &&
      _sameColumns(reminderColumns, {
        ...schema13ReminderColumns,
        ...schema14CaptureReminderColumns,
      })) {
    return Schema14Shape.captureFlow;
  }
  return null;
}

/// Returns static SQL only after the source shape has been identified.
List<String> schema14UpgradeStatements(Schema14Shape shape) => switch (shape) {
  Schema14Shape.reminderOrigin => [
    'ALTER TABLE Settings ADD COLUMN workspace_drafts_json TEXT',
    'ALTER TABLE Reminders ADD COLUMN event_time TEXT',
    'ALTER TABLE Reminders ADD COLUMN recurrence_event_anchor_time TEXT',
    'ALTER TABLE Reminders ADD COLUMN suggested_trigger_time TEXT',
    'ALTER TABLE Reminders ADD COLUMN source_text TEXT',
    'ALTER TABLE Reminders ADD COLUMN capture_pending INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE Reminders ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0',
  ],
  Schema14Shape.captureFlow => [
    "ALTER TABLE Reminders ADD COLUMN trigger_time_origin TEXT NOT NULL DEFAULT 'unknown'",
  ],
};
