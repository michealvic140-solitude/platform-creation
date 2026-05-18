
CREATE OR REPLACE FUNCTION public.settle_pay_winning_bet(_bet_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE b record; new_balance bigint; new_house bigint; paused boolean;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT payouts_paused INTO paused FROM house_wallet WHERE id=1;
  IF paused THEN RAISE EXCEPTION 'Payouts paused'; END IF;
  SELECT * INTO b FROM bets WHERE id=_bet_id FOR UPDATE;
  IF b IS NULL THEN RAISE EXCEPTION 'Bet not found'; END IF;
  IF b.status IN ('won','refunded','void','cashed_out') THEN
    RAISE EXCEPTION 'Bet already settled (%)', b.status;
  END IF;
  UPDATE profiles SET token_balance = token_balance + b.potential_payout
    WHERE id=b.user_id RETURNING token_balance INTO new_balance;
  UPDATE bets SET status='won', settled_at=now() WHERE id=_bet_id;
  UPDATE house_wallet SET balance = balance - b.potential_payout,
    total_out = total_out + b.potential_payout, updated_at=now()
    WHERE id=1 RETURNING balance INTO new_house;
  INSERT INTO house_transactions(kind, amount, balance_after, actor_id, reason)
    VALUES ('bet_payout', -b.potential_payout, new_house, auth.uid(), 'Payout for bet '||COALESCE(b.tracking_id, _bet_id::text));
  INSERT INTO token_transactions(user_id, amount, balance_after, kind, description)
    VALUES (b.user_id, b.potential_payout, new_balance, 'bet_win', 'Win: '||COALESCE(b.tracking_id, _bet_id::text));
  INSERT INTO notifications(user_id, title, body, link)
    VALUES (b.user_id, '🎉 Bet won!', 'You won '||b.potential_payout||' tokens.', '/ticket/'||_bet_id);
  RETURN jsonb_build_object('credited', b.potential_payout, 'balance', new_balance);
END $$;

CREATE OR REPLACE FUNCTION public.admin_refund_bet(_bet_id uuid, _reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE b record; new_balance bigint;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO b FROM bets WHERE id=_bet_id FOR UPDATE;
  IF b IS NULL THEN RAISE EXCEPTION 'Bet not found'; END IF;
  IF b.status IN ('refunded','void','won','cashed_out') THEN
    RAISE EXCEPTION 'Bet not refundable (%)', b.status;
  END IF;
  UPDATE profiles SET token_balance = token_balance + b.stake
    WHERE id=b.user_id RETURNING token_balance INTO new_balance;
  UPDATE bets SET status='refunded', settled_at=now() WHERE id=_bet_id;
  INSERT INTO token_transactions(user_id, amount, balance_after, kind, description)
    VALUES (b.user_id, b.stake, new_balance, 'bet_refund', COALESCE(_reason, 'Refund: '||COALESCE(b.tracking_id, _bet_id::text)));
  INSERT INTO notifications(user_id, title, body, link)
    VALUES (b.user_id, 'Bet refunded', 'Your stake of '||b.stake||' tokens has been refunded.'||CASE WHEN _reason IS NOT NULL THEN ' Reason: '||_reason ELSE '' END, '/ticket/'||_bet_id);
  RETURN jsonb_build_object('refunded', b.stake, 'balance', new_balance);
END $$;
