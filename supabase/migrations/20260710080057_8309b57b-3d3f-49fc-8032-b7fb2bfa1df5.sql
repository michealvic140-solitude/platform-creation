REVOKE ALL ON FUNCTION public._settle_lottery_draw(uuid, integer[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auto_draw_due_lotteries() FROM PUBLIC, anon, authenticated;