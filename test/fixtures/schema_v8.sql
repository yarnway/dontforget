-- Historical schema v8 from candidate fd74ad9. Its SQL matches v7. v8 removed bundled credentials.
-- Frozen for native candidate acceptance and migration tests. No credentials or user data.
CREATE TABLE Settings (
  id TEXT NOT NULL,
  api_key TEXT,
  base_url TEXT,
  model_name TEXT,
  language TEXT
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
  FOREIGN KEY (record_id) REFERENCES MediaRecords (id) ON DELETE CASCADE
);
