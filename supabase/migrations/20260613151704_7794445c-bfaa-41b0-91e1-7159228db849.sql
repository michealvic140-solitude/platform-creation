CREATE OR REPLACE FUNCTION public.user_cashout_bet(_bet_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  b record;
  total_sels int; winning_sels int; won_sels int; pending_sels int;
  payout bigint; factor numeric := 0.80; is_full boolean;
  new_bal bigint; new_house bigint; paused boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT payouts_paused INTO paused FROM public.house_wallet WHERE id = 1;
  IF paused THEN RAISE EXCEPTION 'Payouts are temporarily paused by the house. Please try again later.'; END IF;

  SELECT * INTO b FROM public.bets WHERE id = _bet_id FOR UPDATE;
  IF b IS NULL THEN RAISE EXCEPTION 'Ticket not found'; END IF;
  IF b.user_id <> auth.uid() THEN RAISE EXCEPTION 'Not your ticket'; END IF;
  IF b.status <> 'open' THEN RAISE EXCEPTION 'Ticket is %, cannot cash out', b.status; END IF;

  WITH s AS (
    SELECT bs.result, bs.selection_label,
           o.future_status,
           m.match_kind, m.status AS mstatus, m.home_score, m.away_score,
           ht.name AS home_name, at.name AS away_name,
           mk.name AS market_name
    FROM public.bet_selections bs
    JOIN public.odds o ON o.id = bs.odd_id
    LEFT JOIN public.matches m ON m.id = bs.match_id
    LEFT JOIN public.teams ht ON ht.id = m.home_team_id
    LEFT JOIN public.teams at ON at.id = m.away_team_id
    LEFT JOIN public.markets mk ON mk.id = bs.market_id
    WHERE bs.bet_id = _bet_id
  ), evaluated AS (
    SELECT result,
      CASE
        WHEN result = 'won' THEN true
        WHEN result = 'lost' THEN false
        WHEN match_kind = 'future' THEN future_status IN ('qualified','winner')
        WHEN mstatus NOT IN ('live','ended') THEN false
        WHEN market_name = 'Correct Score' THEN selection_label = (home_score::text || '-' || away_score::text)
        ELSE selection_label = CASE
              WHEN home_score > away_score THEN home_name
              WHEN away_score > home_score THEN away_name
              ELSE 'Draw' END
      END AS winning
    FROM s
  )
  SELECT count(*),
         count(*) FILTER (WHERE winning IS TRUE),
         count(*) FILTER (WHERE result = 'won'),
         count(*) FILTER (WHERE result IS NULL)
  INTO total_sels, winning_sels, won_sels, pending_sels
  FROM evaluated;

  IF total_sels = 0 THEN RAISE EXCEPTION 'No selections on this ticket'; END IF;
  IF winning_sels < total_sels THEN
    RAISE EXCEPTION 'Cash-out locked: every selection must be winning so far';
  END IF;

  is_full := (won_sels = total_sels AND pending_sels = 0);
  payout := CASE WHEN is_full THEN b.potential_payout ELSE floor(b.potential_payout * factor)::bigint END;
  IF payout < 1 THEN payout := 1; END IF;

  UPDATE public.profiles SET token_balance = token_balance + payout
    WHERE id = b.user_id RETURNING token_balance INTO new_bal;
  UPDATE public.house_wallet
    SET balance = balance - payout, total_out = total_out + payout, updated_at = now()
    WHERE id = 1 RETURNING balance INTO new_house;
  INSERT INTO public.house_transactions(kind, amount, balance_after, user_id, bet_id, reason)
    VALUES ('cashout', -payout, new_house, b.user_id, b.id, 'Cashout of bet ' || b.tracking_id);

  UPDATE public.bets SET status = 'cashed_out', cashout_amount = payout,
         cashed_out_at = now(), settled_at = COALESCE(settled_at, now())
    WHERE id = _bet_id;
  INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (b.user_id, 'Ticket cashed out', '+' || payout || ' tokens credited.', '/ticket/'||_bet_id);

  RETURN jsonb_build_object('credited', payout, 'balance', new_bal, 'full', is_full);
END $function$;