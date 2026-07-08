REVOKE EXECUTE ON FUNCTION public.submit_survey(uuid, jsonb) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.dismiss_survey(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.submit_survey(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dismiss_survey(uuid) TO authenticated;