GRANT SELECT, INSERT, UPDATE, DELETE ON public.surveys TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.survey_responses TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.lottery_draws TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.lottery_tickets TO authenticated;

GRANT ALL ON public.surveys TO service_role;
GRANT ALL ON public.survey_responses TO service_role;
GRANT ALL ON public.lottery_draws TO service_role;
GRANT ALL ON public.lottery_tickets TO service_role;