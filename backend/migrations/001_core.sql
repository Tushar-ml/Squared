-- Core splitting domain (stands in for the existing Splitwise backend).
-- Rewards never write to these tables except the additive `version` column.

CREATE TABLE IF NOT EXISTS users (
  id bigserial PRIMARY KEY,
  phone text NOT NULL UNIQUE,
  name text NOT NULL DEFAULT '',
  email text,
  upi_id text,
  phone_verified boolean NOT NULL DEFAULT false,
  role text NOT NULL DEFAULT 'USER' CHECK (role IN ('USER','OPS')),
  device_fingerprint text,
  hide_coins boolean NOT NULL DEFAULT false,
  intro_seen boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS otp_codes (
  phone text PRIMARY KEY,
  code text NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token text PRIMARY KEY,
  user_id bigint NOT NULL REFERENCES users(id),
  device_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS groups (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  group_type text NOT NULL DEFAULT 'HOME' CHECK (group_type IN ('HOME','TRIP','COUPLE','OTHER')),
  country text NOT NULL DEFAULT 'IN',
  expected_members int,
  created_by bigint NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS group_members (
  group_id bigint NOT NULL REFERENCES groups(id),
  user_id bigint NOT NULL REFERENCES users(id),
  joined_at timestamptz NOT NULL DEFAULT now(),
  left_at timestamptz,
  referral_id uuid,
  PRIMARY KEY (group_id, user_id)
);

CREATE TABLE IF NOT EXISTS expenses (
  id bigserial PRIMARY KEY,
  group_id bigint NOT NULL REFERENCES groups(id),
  description text NOT NULL,
  amount_paise bigint NOT NULL CHECK (amount_paise > 0),
  currency text NOT NULL DEFAULT 'INR',
  paid_by bigint NOT NULL REFERENCES users(id),
  created_by bigint NOT NULL REFERENCES users(id),
  version int NOT NULL DEFAULT 1,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS expenses_group_idx ON expenses (group_id, created_at DESC);

CREATE TABLE IF NOT EXISTS expense_splits (
  expense_id bigint NOT NULL REFERENCES expenses(id),
  user_id bigint NOT NULL REFERENCES users(id),
  share_paise bigint NOT NULL CHECK (share_paise >= 0),
  PRIMARY KEY (expense_id, user_id)
);

CREATE TABLE IF NOT EXISTS payments (
  id bigserial PRIMARY KEY,
  group_id bigint NOT NULL REFERENCES groups(id),
  payer_id bigint NOT NULL REFERENCES users(id),
  receiver_id bigint NOT NULL REFERENCES users(id),
  amount_paise bigint NOT NULL CHECK (amount_paise > 0),
  note text,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS payments_group_idx ON payments (group_id, created_at DESC);

-- Transactional outbox: written in the same transaction as the core change.
CREATE TABLE IF NOT EXISTS outbox_events (
  id bigserial PRIMARY KEY,
  event_id uuid NOT NULL UNIQUE,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  attempts int NOT NULL DEFAULT 0,
  last_error text
);
CREATE INDEX IF NOT EXISTS outbox_pending_idx ON outbox_events (id) WHERE processed_at IS NULL;
