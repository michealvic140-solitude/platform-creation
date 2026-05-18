
CREATE OR REPLACE FUNCTION public.server_now()
 RETURNS timestamptz
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ SELECT now() $function$;

GRANT EXECUTE ON FUNCTION public.server_now() TO anon, authenticated;
