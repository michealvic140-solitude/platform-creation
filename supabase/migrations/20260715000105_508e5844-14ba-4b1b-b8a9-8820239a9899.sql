ALTER TABLE public.home_banners
  ADD COLUMN IF NOT EXISTS image_fit text NOT NULL DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS image_position text NOT NULL DEFAULT 'center';