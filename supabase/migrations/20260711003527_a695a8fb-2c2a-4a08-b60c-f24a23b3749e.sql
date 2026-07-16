ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS featured_image_url text,
  ADD COLUMN IF NOT EXISTS featured_image_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS featured_image_position text DEFAULT 'center';