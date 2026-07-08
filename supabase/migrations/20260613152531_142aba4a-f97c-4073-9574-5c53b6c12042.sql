ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS allow_rebet boolean NOT NULL DEFAULT true;