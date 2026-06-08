ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS leaderboard_gangs_reset_at timestamptz,
  ADD COLUMN IF NOT EXISTS leaderboard_shooters_reset_at timestamptz,
  ADD COLUMN IF NOT EXISTS hall_of_fame_reset_at timestamptz;

CREATE OR REPLACE FUNCTION public.fix_pending_virtual_bets()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  bet record;
  total_sel int;
  ended_sel int;
  lost_sel int;
  won_sel int;
  fixed int := 0;
BEGIN
  FOR bet IN
    SELECT DISTINCT b.* FROM public.bets b
    JOIN public.bet_selections bs ON bs.bet_id = b.id
    WHERE b.status = 'open'
  LOOP
    UPDATE public.bet_selections bs
      SET result = CASE WHEN o.is_winner IS TRUE THEN 'won' ELSE 'lost' END
      FROM public.odds o, public.matches m
      WHERE bs.bet_id = bet.id
        AND bs.odd_id = o.id
        AND bs.match_id = m.id
        AND m.status = 'ended'
        AND bs.result IS NULL;

    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE m.status = 'ended'),
           COUNT(*) FILTER (WHERE bs.result = 'lost'),
           COUNT(*) FILTER (WHERE bs.result = 'won')
      INTO total_sel, ended_sel, lost_sel, won_sel
      FROM public.bet_selections bs JOIN public.matches m ON m.id = bs.match_id
     WHERE bs.bet_id = bet.id;

    IF lost_sel > 0 THEN
      UPDATE public.bets SET status='lost', settled_at = COALESCE(settled_at, now()) WHERE id = bet.id;
      fixed := fixed + 1;
    ELSIF ended_sel = total_sel AND total_sel > 0 AND won_sel = total_sel THEN
      UPDATE public.bets SET status='won', settled_at = COALESCE(settled_at, now()) WHERE id = bet.id;
      fixed := fixed + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'fixed', fixed);
END $$;

CREATE OR REPLACE FUNCTION public.claim_virtual_payout(_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; new_bal bigint; wallet_bal bigint;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO r FROM virtual_payout_requests WHERE id = _id FOR UPDATE;
  IF r IS NULL OR r.user_id <> auth.uid() THEN RAISE EXCEPTION 'Not yours'; END IF;
  IF r.status = 'claimed' THEN RAISE EXCEPTION 'Already claimed'; END IF;
  IF r.status = 'declined' THEN RAISE EXCEPTION 'Payout was declined'; END IF;

  SELECT balance INTO wallet_bal FROM virtual_house_wallet WHERE id=1 FOR UPDATE;
  IF wallet_bal < r.amount THEN
    RAISE EXCEPTION 'Virtual wallet has insufficient funds (need %, have %)', r.amount, wallet_bal USING ERRCODE='P0001';
  END IF;

  PERFORM public.virtual_wallet_debit(r.amount, 'payout', r.user_id, r.bet_id, r.match_id, 'Virtual payout claim');
  UPDATE profiles SET token_balance = token_balance + r.amount,
      xp = xp + COALESCE((SELECT virtual_xp_per_win FROM app_settings WHERE id=1),0)
    WHERE id = auth.uid() RETURNING token_balance INTO new_bal;
  INSERT INTO token_transactions(user_id, amount, balance_after, kind, description)
    VALUES (auth.uid(), r.amount, new_bal, 'bet_win', 'Virtual claim');
  UPDATE virtual_payout_requests
    SET status='claimed', claimed_at=now(),
        reviewed_by = COALESCE(reviewed_by, auth.uid()),
        reviewed_at = COALESCE(reviewed_at, now())
    WHERE id=_id;
  RETURN jsonb_build_object('ok', true, 'amount', r.amount, 'balance', new_bal);
END $$;

CREATE OR REPLACE FUNCTION public.trg_fix_pending_after_match_end()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'ended' AND (OLD.status IS DISTINCT FROM 'ended') THEN
    BEGIN
      PERFORM public.fix_pending_virtual_bets();
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS matches_fix_pending_bets ON public.matches;
CREATE TRIGGER matches_fix_pending_bets
AFTER UPDATE OF status ON public.matches
FOR EACH ROW EXECUTE FUNCTION public.trg_fix_pending_after_match_end();

SELECT public.fix_pending_virtual_bets();