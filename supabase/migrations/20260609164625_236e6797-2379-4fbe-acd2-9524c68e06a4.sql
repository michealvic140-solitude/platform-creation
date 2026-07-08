DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
           WHERE n.nspname='public' AND c.relkind='r'
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t.relname);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t.relname);
  END LOOP;
END $$;

GRANT SELECT ON public.advertisements TO anon;
GRANT SELECT ON public.announcements TO anon;
GRANT SELECT ON public.app_settings TO anon;
GRANT SELECT ON public.ban_appeals TO anon;
GRANT SELECT ON public.categories TO anon;
GRANT SELECT ON public.events TO anon;
GRANT SELECT ON public.highlights TO anon;
GRANT SELECT ON public.leaderboard_overrides TO anon;
GRANT SELECT ON public.markets TO anon;
GRANT SELECT ON public.matches TO anon;
GRANT SELECT ON public.odds TO anon;
GRANT SELECT ON public.players TO anon;
GRANT SELECT ON public.season_points TO anon;
GRANT SELECT ON public.seasons TO anon;
GRANT SELECT ON public.spotlights TO anon;
GRANT SELECT ON public.teams TO anon;
GRANT SELECT ON public.token_transactions TO anon;