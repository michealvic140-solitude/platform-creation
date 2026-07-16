
-- Sync paired bets rows for all settled championship_bets (auto championship/cup vouchers)
CREATE OR REPLACE FUNCTION public.resolve_auto_championship()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b RECORD;
  n INT := 0;
BEGIN
  FOR b IN
    SELECT bt.id AS bet_id, cb.status AS cb_status, cb.payout AS cb_payout, bt.potential_payout
      FROM public.bets bt
      JOIN public.championship_bets cb ON cb.id = bt.championship_bet_id
     WHERE bt.status = 'open'
       AND cb.status IN ('won','lost','void')
  LOOP
    IF b.cb_status = 'won' THEN
      UPDATE public.bets
         SET status = 'won'::bet_status,
             cashout_amount = COALESCE(NULLIF(b.cb_payout,0), b.potential_payout),
             settled_at = now()
       WHERE id = b.bet_id AND status = 'open';
    ELSIF b.cb_status = 'lost' THEN
      UPDATE public.bets
         SET status = 'lost'::bet_status,
             cashout_amount = 0,
             settled_at = now()
       WHERE id = b.bet_id AND status = 'open';
    ELSE
      UPDATE public.bets
         SET status = 'void'::bet_status,
             cashout_amount = 0,
             settled_at = now()
       WHERE id = b.bet_id AND status = 'open';
    END IF;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_auto_championship() TO authenticated, service_role, anon;

-- Ensure credit_championship_payouts also finalizes the paired bets voucher rows
CREATE OR REPLACE FUNCTION public.credit_championship_payouts(p_tournament uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b RECORD;
BEGIN
  FOR b IN
    SELECT user_id, SUM(payout) AS total
      FROM public.championship_bets
     WHERE tournament_id = p_tournament
       AND status = 'won'
       AND payout > 0
     GROUP BY user_id
  LOOP
    UPDATE public.profiles SET token_balance = token_balance + b.total WHERE id = b.user_id;
    INSERT INTO public.token_transactions (user_id, amount, kind, description)
      VALUES (b.user_id, b.total, 'championship_win', 'Championship Virtual payout')
      ON CONFLICT DO NOTHING;
  END LOOP;

  -- Finalize paired voucher rows for this tournament
  UPDATE public.bets bt
     SET status = 'won'::bet_status,
         cashout_amount = COALESCE(NULLIF(cb.payout,0), bt.potential_payout),
         settled_at = now()
    FROM public.championship_bets cb
   WHERE cb.id = bt.championship_bet_id
     AND cb.tournament_id = p_tournament
     AND cb.status = 'won'
     AND bt.status = 'open';

  UPDATE public.bets bt
     SET status = 'lost'::bet_status,
         cashout_amount = 0,
         settled_at = now()
    FROM public.championship_bets cb
   WHERE cb.id = bt.championship_bet_id
     AND cb.tournament_id = p_tournament
     AND cb.status = 'lost'
     AND bt.status = 'open';

  UPDATE public.bets bt
     SET status = 'void'::bet_status,
         cashout_amount = 0,
         settled_at = now()
    FROM public.championship_bets cb
   WHERE cb.id = bt.championship_bet_id
     AND cb.tournament_id = p_tournament
     AND cb.status = 'void'
     AND bt.status = 'open';
END;
$$;

-- Backfill: resolve any already-completed auto championship/cup vouchers still stuck open
SELECT public.resolve_auto_championship();
