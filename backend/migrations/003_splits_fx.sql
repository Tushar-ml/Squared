-- Unequal splits, categories and multi-currency. Additive only (I-8).
ALTER TABLE groups ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'INR';

-- expenses.amount_paise / currency are in the GROUP currency (what balances use).
-- original_* keep what the user typed when it was another currency, with the rate snapshot.
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS split_type text NOT NULL DEFAULT 'EQUAL'
  CHECK (split_type IN ('EQUAL','EXACT','PERCENT','SHARES'));
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS split_meta jsonb NOT NULL DEFAULT '{}';
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS category text NOT NULL DEFAULT 'other';
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS original_currency text;
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS original_amount_minor bigint;
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS fx_rate numeric(24,12);

CREATE TABLE IF NOT EXISTS fx_rates (
  base text NOT NULL,
  quote text NOT NULL,
  rate numeric(24,12) NOT NULL,
  as_of timestamptz NOT NULL,
  source text NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (base, quote)
);
