
-- Championship Virtual admin toggle
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS virtual_championship_enabled boolean NOT NULL DEFAULT false;

-- Tournament fields to support the 16-team virtual knockout format
ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'legacy',
  ADD COLUMN IF NOT EXISTS starts_at timestamptz,
  ADD COLUMN IF NOT EXISTS current_stage text,
  ADD COLUMN IF NOT EXISTS stage_gap_seconds integer NOT NULL DEFAULT 20,
  ADD COLUMN IF NOT EXISTS bracket_size integer NOT NULL DEFAULT 16;

CREATE INDEX IF NOT EXISTS idx_tournaments_kind_status
  ON public.tournaments (kind, status, starts_at);
