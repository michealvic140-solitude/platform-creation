ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS leaderboard_header_url text;

UPDATE public.app_settings
  SET leaderboard_header_url = '/__l5e/assets-v1/3e785487-fb67-4d21-9956-89ae56dbfab1/leaderboard-header.png'
  WHERE id = 1 AND (leaderboard_header_url IS NULL OR leaderboard_header_url = '');