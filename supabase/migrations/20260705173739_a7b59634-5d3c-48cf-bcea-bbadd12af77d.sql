DO $$
BEGIN
  EXECUTE 'GRANT SELECT ON TABLE public.matches TO anon';
  EXECUTE 'GRANT SELECT ON TABLE public.matches TO authenticated';
  EXECUTE 'GRANT ALL ON TABLE public.matches TO service_role';

  EXECUTE 'GRANT SELECT ON TABLE public.teams TO anon';
  EXECUTE 'GRANT SELECT ON TABLE public.teams TO authenticated';
  EXECUTE 'GRANT ALL ON TABLE public.teams TO service_role';

  EXECUTE 'GRANT SELECT ON TABLE public.markets TO anon';
  EXECUTE 'GRANT SELECT ON TABLE public.markets TO authenticated';
  EXECUTE 'GRANT ALL ON TABLE public.markets TO service_role';

  EXECUTE 'GRANT SELECT ON TABLE public.odds TO anon';
  EXECUTE 'GRANT SELECT ON TABLE public.odds TO authenticated';
  EXECUTE 'GRANT ALL ON TABLE public.odds TO service_role';

  EXECUTE 'GRANT SELECT ON TABLE public.categories TO anon';
  EXECUTE 'GRANT SELECT ON TABLE public.categories TO authenticated';
  EXECUTE 'GRANT ALL ON TABLE public.categories TO service_role';

  EXECUTE 'GRANT SELECT ON TABLE public.app_settings TO anon';
  EXECUTE 'GRANT SELECT ON TABLE public.app_settings TO authenticated';
  EXECUTE 'GRANT ALL ON TABLE public.app_settings TO service_role';
END $$;