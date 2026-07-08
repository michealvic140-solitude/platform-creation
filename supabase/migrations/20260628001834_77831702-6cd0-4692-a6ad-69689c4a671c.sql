REVOKE EXECUTE ON FUNCTION public._casino_settle(uuid, text, bigint, bigint, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.place_lottery_ticket_multi(uuid, integer[], bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.redeem_shop_item(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.play_coinflip(text, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.play_wheel(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.play_scratch() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.answer_trivia(uuid, integer) FROM PUBLIC;