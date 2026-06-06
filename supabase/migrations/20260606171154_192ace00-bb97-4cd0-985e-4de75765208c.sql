-- Add missing columns referenced by frontend code
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS virtual_round_batch_id uuid;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS virtual_round_id uuid;
CREATE INDEX IF NOT EXISTS idx_matches_virtual_round_batch_id ON public.matches(virtual_round_batch_id);

ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS virtual_matches_per_round int NOT NULL DEFAULT 5;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS virtual_lock_window_seconds int NOT NULL DEFAULT 30;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS force_reload_at timestamptz;