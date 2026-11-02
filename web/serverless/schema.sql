-- Only anonymous first-visit IDs and unverified X handles. No wallet addresses.
CREATE TABLE IF NOT EXISTS attributions (
  visitor_id TEXT PRIMARY KEY,
  handle TEXT NOT NULL COLLATE NOCASE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS attributions_handle ON attributions(handle);
