-- Squared: any kind of group, plus 1:1 "friend" splits (a hidden 2-person DIRECT group). Additive only.
ALTER TABLE groups DROP CONSTRAINT IF EXISTS groups_group_type_check;
ALTER TABLE groups ADD CONSTRAINT groups_group_type_check
  CHECK (group_type IN ('HOME','TRIP','COUPLE','FRIENDS','WORK','EVENT','OTHER','DIRECT'));
CREATE INDEX IF NOT EXISTS groups_direct_idx ON groups (group_type) WHERE group_type = 'DIRECT';
