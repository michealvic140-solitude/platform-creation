CREATE OR REPLACE FUNCTION public.admin_resolve_virtual_round(
  _match_id uuid,
  _home_score integer DEFAULT NULL,
  _away_score integer DEFAULT NULL,
  _first_blood_team_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  RETURN public.resolve_virtual_round(_match_id, _home_score, _away_score, _first_blood_team_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_set_virtual_cycle(boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_lock_virtual_round(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_virtual_round(uuid, integer, integer, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_resolve_virtual_round(uuid, integer, integer, uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_set_virtual_cycle(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_lock_virtual_round(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_virtual_round(uuid, integer, integer, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_virtual_round(uuid, integer, integer, uuid) TO service_role;