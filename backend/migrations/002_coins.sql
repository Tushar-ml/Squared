-- Reward module (PRD section 8.3). Additive only.

CREATE TABLE IF NOT EXISTS coin_config (
  version int PRIMARY KEY,
  body jsonb NOT NULL,
  created_by bigint,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS wallets (
  id uuid PRIMARY KEY,
  owner_type text NOT NULL CHECK (owner_type IN ('USER','GROUP')),
  owner_id bigint NOT NULL,
  balance_cached int NOT NULL DEFAULT 0,
  deficit int NOT NULL DEFAULT 0,
  redemption_frozen boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_type, owner_id)
);

CREATE TABLE IF NOT EXISTS coin_ledger (
  id uuid PRIMARY KEY,
  wallet_id uuid NOT NULL REFERENCES wallets(id),
  entry_type text NOT NULL CHECK (entry_type IN ('EARN','SPEND','REVERSAL','EXPIRE','REFUND','ADJUST')),
  status text NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED','PENDING','REJECTED')),
  amount int NOT NULL,
  reason_code text NOT NULL,
  source_type text,
  source_id text,
  source_version int,
  group_id bigint,
  counterparty_user_id bigint,
  reverses_entry_id uuid REFERENCES coin_ledger(id),
  idempotency_key text NOT NULL UNIQUE,
  config_version int NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS coin_ledger_wallet_idx ON coin_ledger (wallet_id, created_at DESC);
CREATE INDEX IF NOT EXISTS coin_ledger_source_idx ON coin_ledger (source_type, source_id);

-- Only PENDING -> POSTED/REJECTED transitions are allowed; everything else is append-only (I-3).
CREATE OR REPLACE FUNCTION coin_ledger_guard() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'coin_ledger is append-only';
  END IF;
  IF OLD.status <> 'PENDING' OR NEW.status NOT IN ('POSTED','REJECTED')
     OR NEW.amount <> OLD.amount OR NEW.wallet_id <> OLD.wallet_id
     OR NEW.idempotency_key <> OLD.idempotency_key THEN
    RAISE EXCEPTION 'coin_ledger is append-only (only PENDING status can change)';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS coin_ledger_guard_trg ON coin_ledger;
CREATE TRIGGER coin_ledger_guard_trg BEFORE UPDATE OR DELETE ON coin_ledger
  FOR EACH ROW EXECUTE FUNCTION coin_ledger_guard();

CREATE TABLE IF NOT EXISTS coin_lots (
  id uuid PRIMARY KEY,
  wallet_id uuid NOT NULL REFERENCES wallets(id),
  earn_entry_id uuid NOT NULL REFERENCES coin_ledger(id),
  earned_amount int NOT NULL CHECK (earned_amount > 0),
  remaining int NOT NULL CHECK (remaining >= 0),
  earned_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS coin_lots_open_idx ON coin_lots (wallet_id, expires_at) WHERE remaining > 0;

CREATE TABLE IF NOT EXISTS expense_confirmations (
  expense_id bigint NOT NULL,
  expense_version int NOT NULL,
  user_id bigint NOT NULL,
  status text NOT NULL CHECK (status IN ('CONFIRMED','DISPUTED')),
  dispute_reason text CHECK (dispute_reason IN ('WRONG_AMOUNT','NOT_MINE','OTHER')),
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (expense_id, expense_version, user_id)
);

CREATE TABLE IF NOT EXISTS payment_confirmations (
  payment_id bigint PRIMARY KEY,
  status text NOT NULL CHECK (status IN ('PENDING','CONFIRMED','REJECTED','UNVERIFIED')),
  confirmed_by bigint,
  confirmed_at timestamptz,
  note text,
  expires_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS household_goals (
  group_id bigint NOT NULL,
  week_start date NOT NULL,
  target int NOT NULL,
  progress int NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','MET','MISSED')),
  reward_entry_id uuid REFERENCES coin_ledger(id),
  PRIMARY KEY (group_id, week_start)
);

CREATE TABLE IF NOT EXISTS catalog_items (
  id uuid PRIMARY KEY,
  scope text NOT NULL CHECK (scope IN ('USER','GROUP')),
  brand text NOT NULL,
  category text NOT NULL DEFAULT 'groceries',
  face_value_inr int NOT NULL,
  coin_cost int NOT NULL,
  vendor_sku text NOT NULL,
  funded_by text,
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS redemptions (
  id uuid PRIMARY KEY,
  wallet_id uuid NOT NULL REFERENCES wallets(id),
  redeemed_by bigint NOT NULL,
  group_id bigint,
  catalog_item_id uuid NOT NULL REFERENCES catalog_items(id),
  coins int NOT NULL,
  status text NOT NULL CHECK (status IN ('REQUESTED','HELD','FULFILLED','FAILED','REFUNDED')),
  vendor_ref text,
  code_encrypted bytea,
  failure_code text,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS referrals (
  id uuid PRIMARY KEY,
  inviter_id bigint NOT NULL,
  invitee_id bigint,
  group_id bigint NOT NULL,
  status text NOT NULL CHECK (status IN ('INVITED','JOINED','REWARDED')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS experiment_assignments (
  experiment_key text NOT NULL,
  group_id bigint NOT NULL,
  arm text NOT NULL CHECK (arm IN ('TREATMENT','CONTROL')),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (experiment_key, group_id)
);

CREATE TABLE IF NOT EXISTS ops_audit_log (
  id uuid PRIMARY KEY,
  actor_id bigint NOT NULL,
  action text NOT NULL,
  target_type text NOT NULL,
  target_id text NOT NULL,
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Supporting tables for UI surfaces.
CREATE TABLE IF NOT EXISTS celebrations (
  id uuid PRIMARY KEY,
  user_id bigint NOT NULL,
  kind text NOT NULL CHECK (kind IN ('SETTLEMENT','FIRST_WIN','GOAL')),
  coins int NOT NULL,
  bonus_multiplier int,
  bonus_coins int NOT NULL DEFAULT 0,
  title text NOT NULL,
  source_key text NOT NULL UNIQUE,
  seen_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS reward_notices (
  id bigserial PRIMARY KEY,
  user_id bigint NOT NULL,
  cap_key text NOT NULL,
  source_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, source_key, cap_key)
);

CREATE TABLE IF NOT EXISTS expense_reminders (
  expense_id bigint NOT NULL,
  user_id bigint NOT NULL,
  reminded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS expense_reminders_idx ON expense_reminders (expense_id, user_id, reminded_at DESC);

CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY,
  user_id bigint NOT NULL,
  notification_id text NOT NULL,
  group_id bigint,
  dedupe_key text NOT NULL UNIQUE,
  title text NOT NULL,
  body text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}',
  priority int NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','SENT','INBOX_ONLY','BATCHED','SUPPRESSED')),
  deliver_after timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz,
  delivered_at timestamptz,
  opened_at timestamptz,
  actioned_at timestamptz,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notifications_user_idx ON notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_queue_idx ON notifications (deliver_after) WHERE status = 'QUEUED';

CREATE TABLE IF NOT EXISTS notification_prefs (
  user_id bigint NOT NULL,
  notification_id text NOT NULL,
  enabled boolean NOT NULL,
  PRIMARY KEY (user_id, notification_id)
);

CREATE TABLE IF NOT EXISTS analytics_events (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  user_hash text,
  group_id bigint,
  arm text,
  config_version int,
  platform text,
  app_version text,
  props jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS integrity_reports (
  id bigserial PRIMARY KEY,
  wallet_id uuid NOT NULL,
  detail jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
