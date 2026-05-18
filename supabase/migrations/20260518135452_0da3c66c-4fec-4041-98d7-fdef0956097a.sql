REVOKE ALL ON FUNCTION public.place_virtual_bet(uuid, uuid, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.place_virtual_ticket(jsonb, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.virtual_tick() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.place_virtual_bet(uuid, uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_virtual_ticket(jsonb, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.virtual_tick() TO authenticated;