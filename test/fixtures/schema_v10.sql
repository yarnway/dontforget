-- Schema v10 for ordered model profiles; frozen for candidate schema validation.
-- Synthetic fixture schema only; no credentials or user data.
CREATE TABLE Settings (
  id TEXT NOT NULL,
  api_key TEXT,
  base_url TEXT,
  model_name TEXT,
  language TEXT,
  ai_profiles_json TEXT NOT NULL DEFAULT '[]',
  ai_fallback_enabled INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE MediaRecords (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  content_or_path TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE Reminders (
  id TEXT PRIMARY KEY,
  record_id TEXT,
  task_title TEXT NOT NULL,
  task_summary TEXT,
  quadrant_level INTEGER NOT NULL,
  urgency_level TEXT,
  importance_level TEXT,
  trigger_time TEXT,
  is_completed BOOLEAN NOT NULL,
  is_recurring INTEGER DEFAULT 0,
  recurrence_rule TEXT DEFAULT 'none',
  recurrence_description TEXT,
  is_emotion_filtered INTEGER DEFAULT 0,
  sub_tasks TEXT,
  created_at TEXT,
  review_level INTEGER DEFAULT 0,
  next_review_at TEXT,
  original_quadrant_level INTEGER,
  is_dynamically_promoted INTEGER DEFAULT 0,
  linked_task_ids TEXT,
  context_trigger TEXT,
  notice_revision INTEGER NOT NULL DEFAULT 0,
  notice_acknowledged_at TEXT,
  upcoming_dismissed_at TEXT,
  snoozed_at TEXT,
  recurrence_anchor_time TEXT,
  FOREIGN KEY (record_id) REFERENCES MediaRecords (id) ON DELETE CASCADE
);
