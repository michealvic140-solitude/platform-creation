ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS site_bg_url text,
  ADD COLUMN IF NOT EXISTS admin_hero_url text;