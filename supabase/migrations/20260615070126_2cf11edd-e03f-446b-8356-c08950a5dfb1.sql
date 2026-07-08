CREATE OR REPLACE FUNCTION public.admin_set_virtual_cycle(_running boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  UPDATE public.app_settings SET virtual_cycle_running = _running, updated_at = now() WHERE id = 1;
  PERFORM public.admin_log_action(
    CASE WHEN _running THEN 'virtual_cycle_started' ELSE 'virtual_cycle_paused' END,
    'cycle', '1', jsonb_build_object('manual', true, 'reason', 'Manual virtual cycle control')
  );
  IF _running THEN
    PERFORM public.virtual_tick();
  END IF;
  RETURN jsonb_build_object('ok', true, 'running', _running);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_delete_bet(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_refund_bet(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_void_bet(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_bet(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_refund_bet(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_void_bet(uuid, boolean, text) TO authenticated;