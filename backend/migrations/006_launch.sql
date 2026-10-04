-- Launch hardening: account deletion and OTP abuse limits. Additive only.
ALTER TABLE users ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE otp_codes ADD COLUMN IF NOT EXISTS attempts int NOT NULL DEFAULT 0;
-- one row per code sent, for per-phone and per-IP send limits
CREATE TABLE IF NOT EXISTS otp_sends (
  id bigserial PRIMARY KEY,
  phone text NOT NULL,
  ip text,
  created_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS otp_sends_phone_idx ON otp_sends (phone, created_at);
CREATE INDEX IF NOT EXISTS otp_sends_ip_idx ON otp_sends (ip, created_at);
