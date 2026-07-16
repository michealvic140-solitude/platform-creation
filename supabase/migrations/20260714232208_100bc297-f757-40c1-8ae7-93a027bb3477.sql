
CREATE OR REPLACE FUNCTION public.resolve_open_bets()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  b RECORD;
  s RECORD;
  n INT := 0;
  cfg RECORD;
  payout_amount BIGINT;
  m_id UUID;
  is_virt BOOLEAN;
  unresolved INT;
  has_lost BOOLEAN;
  all_void BOOLEAN;
BEGIN
  SELECT virtual_payout_multiplier, virtual_win_bonus_tokens INTO cfg FROM public.app_settings WHERE id = 1;

  -- 1) Selection-backed vouchers (sports / virtual sports).
  FOR b IN
    SELECT bt.*
      FROM public.bets bt
     WHERE bt.status = 'open'
       AND bt.championship_bet_id IS NULL
       AND EXISTS (SELECT 1 FROM public.bet_selections bs WHERE bs.bet_id = bt.id)
  LOOP
    -- Fill in any selections whose match has ended but result is still NULL.
    UPDATE public.bet_selections bs
       SET result = CASE
              WHEN o.is_winner IS TRUE THEN 'won'
              WHEN o.is_winner IS FALSE THEN 'lost'
              ELSE bs.result END
      FROM public.odds o, public.matches mt
     WHERE bs.bet_id = b.id
       AND bs.odd_id = o.id
       AND bs.match_id = mt.id
       AND mt.status = 'ended'
       AND bs.result IS NULL;

    SELECT COUNT(*) FILTER (WHERE bs2.result IS NULL),
           COALESCE(bool_or(bs2.result = 'lost'), false),
           COALESCE(bool_and(bs2.result = 'void'), false)
      INTO unresolved, has_lost, all_void
      FROM public.bet_selections bs2 WHERE bs2.bet_id = b.id;

    IF has_lost THEN
      UPDATE public.bets SET status = 'lost', cashout_amount = 0, settled_at = COALESCE(settled_at, now())
       WHERE id = b.id AND status = 'open';
      INSERT INTO public.notifications (user_id, title, body, link)
        VALUES (b.user_id, 'Bet lost', 'Your ticket ' || b.tracking_id || ' did not win this round.', '/ticket/' || b.id::text);
      n := n + 1;
    ELSIF unresolved = 0 THEN
      IF all_void THEN
        UPDATE public.bets SET status = 'void', cashout_amount = b.stake, settled_at = COALESCE(settled_at, now())
         WHERE id = b.id AND status = 'open';
        UPDATE public.profiles SET token_balance = token_balance + b.stake WHERE id = b.user_id;
        INSERT INTO public.notifications (user_id, title, body, link)
          VALUES (b.user_id, 'Bet voided', b.tracking_id || ' was voided; stake returned.', '/ticket/' || b.id::text);
      ELSE
        SELECT COALESCE(bool_or(mt.is_virtual), false) INTO is_virt
          FROM public.bet_selections bs3 JOIN public.matches mt ON mt.id = bs3.match_id WHERE bs3.bet_id = b.id;
        UPDATE public.bets SET status = 'won', cashout_amount = b.potential_payout, settled_at = COALESCE(settled_at, now())
         WHERE id = b.id AND status = 'open';
        IF is_virt THEN
          payout_amount := (b.potential_payout * COALESCE(cfg.virtual_payout_multiplier, 1.0))::bigint + COALESCE(cfg.virtual_win_bonus_tokens, 0);
          INSERT INTO public.virtual_payout_requests(bet_id, user_id, match_id, stake, amount, status)
            SELECT b.id, b.user_id, bs.match_id, b.stake, payout_amount, 'pending'
              FROM public.bet_selections bs WHERE bs.bet_id = b.id LIMIT 1
            ON CONFLICT (bet_id) DO NOTHING;
          INSERT INTO public.notifications (user_id, title, body, link)
            VALUES (b.user_id, 'Virtual ticket won — claim now',
                    b.tracking_id || ' is eligible for a ' || payout_amount::text || ' token payout.',
                    '/virtual/history');
        ELSE
          UPDATE public.profiles SET token_balance = token_balance + b.potential_payout WHERE id = b.user_id;
          INSERT INTO public.token_transactions (user_id, amount, kind, description)
            VALUES (b.user_id, b.potential_payout, 'bet_won', 'Win ' || b.tracking_id) ON CONFLICT DO NOTHING;
          INSERT INTO public.notifications (user_id, title, body, link)
            VALUES (b.user_id, 'Ticket won', b.tracking_id || ' paid ' || b.potential_payout::text || ' tokens.', '/ticket/' || b.id::text);
        END IF;
      END IF;
      n := n + 1;
    END IF;
  END LOOP;

  -- 2) Championship-backed vouchers (delegate to existing resolver).
  n := n + COALESCE(public.resolve_auto_championship(), 0);

  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_open_bets() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_open_bets() TO service_role;

-- Backfill anything currently stuck.
SELECT public.resolve_open_bets();
