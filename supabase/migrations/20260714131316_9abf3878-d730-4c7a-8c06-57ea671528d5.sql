
CREATE OR REPLACE FUNCTION public.prune_dead_push_subscriptions()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  deleted_count integer;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  WITH d AS (
    DELETE FROM public.push_subscriptions
    WHERE enabled = false
       OR (disabled_at IS NOT NULL AND disabled_at < now() - interval '14 days')
       OR failure_count >= 10
       OR last_seen_at < now() - interval '60 days'
    RETURNING 1
  )
  SELECT count(*)::int INTO deleted_count FROM d;
  RETURN deleted_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.prune_dead_push_subscriptions() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.prune_dead_push_subscriptions() TO authenticated;
