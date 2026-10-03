-- Recurring bills, comments, attachments, budgets, chat, devices, preferences. Additive only.
ALTER TABLE groups ADD COLUMN IF NOT EXISTS simplify_debts boolean NOT NULL DEFAULT false;
ALTER TABLE groups ADD COLUMN IF NOT EXISTS default_split jsonb;          -- saved default split (FR-16)
ALTER TABLE users ADD COLUMN IF NOT EXISTS locale text NOT NULL DEFAULT 'en';
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS recurring_id uuid;

CREATE TABLE IF NOT EXISTS recurring_expenses (
  id uuid PRIMARY KEY,
  group_id bigint NOT NULL REFERENCES groups(id),
  created_by bigint NOT NULL REFERENCES users(id),
  description text NOT NULL,
  amount_minor bigint NOT NULL CHECK (amount_minor > 0),
  currency text NOT NULL,
  paid_by bigint NOT NULL REFERENCES users(id),
  split_type text NOT NULL DEFAULT 'EQUAL',
  split_input jsonb NOT NULL DEFAULT '{}',
  category text NOT NULL DEFAULT 'other',
  frequency text NOT NULL CHECK (frequency IN ('WEEKLY','MONTHLY')),
  day int NOT NULL,                     -- day of month (1-28) or weekday (0=Mon)
  next_run date NOT NULL,
  last_run date,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS recurring_due_idx ON recurring_expenses (next_run) WHERE active;

CREATE TABLE IF NOT EXISTS expense_comments (
  id uuid PRIMARY KEY,
  expense_id bigint NOT NULL REFERENCES expenses(id),
  user_id bigint NOT NULL REFERENCES users(id),
  body text NOT NULL,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS expense_comments_idx ON expense_comments (expense_id, created_at);

CREATE TABLE IF NOT EXISTS expense_attachments (
  id uuid PRIMARY KEY,
  expense_id bigint NOT NULL REFERENCES expenses(id),
  user_id bigint NOT NULL REFERENCES users(id),
  path text NOT NULL,
  content_type text NOT NULL,
  bytes int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS group_budgets (
  group_id bigint NOT NULL REFERENCES groups(id),
  category text NOT NULL,
  monthly_limit bigint NOT NULL CHECK (monthly_limit > 0),
  updated_by bigint,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, category)
);

CREATE TABLE IF NOT EXISTS group_messages (
  id uuid PRIMARY KEY,
  group_id bigint NOT NULL REFERENCES groups(id),
  user_id bigint NOT NULL REFERENCES users(id),
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS group_messages_idx ON group_messages (group_id, created_at DESC);

CREATE TABLE IF NOT EXISTS devices (
  token text PRIMARY KEY,
  user_id bigint NOT NULL REFERENCES users(id),
  platform text NOT NULL DEFAULT 'ios',
  updated_at timestamptz NOT NULL DEFAULT now()
);
