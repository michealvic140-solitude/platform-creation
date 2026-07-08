ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS site_name text,
  ADD COLUMN IF NOT EXISTS site_logo_url text,
  ADD COLUMN IF NOT EXISTS site_bg_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS site_bg_position text DEFAULT 'center',
  ADD COLUMN IF NOT EXISTS admin_hero_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS admin_hero_position text DEFAULT 'center right';