ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS hot_bets_reset_at timestamptz,
  ADD COLUMN IF NOT EXISTS maintenance_image text,
  ADD COLUMN IF NOT EXISTS closed_image text;