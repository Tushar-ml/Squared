-- Sign in with Google / Apple replaces phone OTP. Phone numbers are no longer collected.
ALTER TABLE users ALTER COLUMN phone DROP NOT NULL;
ALTER TABLE users RENAME COLUMN phone_verified TO verified;      -- signed in with a verified Google/Apple identity
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_sub text UNIQUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_sub text UNIQUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_refresh_token text;   -- only so account deletion can revoke it
UPDATE users SET email = lower(trim(email)) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS users_email_active_idx ON users (email) WHERE email IS NOT NULL AND deleted_at IS NULL;
DROP TABLE IF EXISTS otp_codes;
DROP TABLE IF EXISTS otp_sends;
