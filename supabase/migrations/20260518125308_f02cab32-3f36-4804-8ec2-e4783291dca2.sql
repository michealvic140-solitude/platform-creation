
-- 1. Virtual house wallet
CREATE TABLE IF NOT EXISTS public.virtual_house_wallet (
  id integer PRIMARY KEY DEFAULT 1,
  balance bigint NOT NULL DEFAULT 0,
  total_in bigint NOT NULL DEFAULT 0,
  total_out bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vhw_singleton CHECK (id = 1)
);
INSERT INTO public.virtual_house_wallet(id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.virtual_house_wallet ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "vhw admin read" ON public.virtual_house_wallet;
CREATE POLICY "vhw admin read" ON public.virtual_house_wallet FOR SELECT TO authenticated USING (is_admin(auth.uid()));
DROP POLICY IF EXISTS "vhw admin update" ON public.virtual_house_wallet;
CREATE POLICY "vhw admin update" ON public.virtual_house_wallet FOR UPDATE TO authenticated USING (is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.virtual_house_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  amount bigint NOT NULL,
  balance_after bigint NOT NULL,
  user_id uuid,
  bet_id uuid,
  match_id uuid,
  actor_id uuid,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.virtual_house_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "vht admin read" ON public.virtual_house_transactions;
CREATE POLICY "vht admin read" ON public.virtual_house_transactions FOR SELECT TO authenticated USING (is_admin(auth.uid()));

-- 2. Concurrent rounds setting
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS virtual_concurrent_rounds integer NOT NULL DEFAULT 4;

-- 3. Wallet helpers
CREATE OR REPLACE FUNCTION public.virtual_wallet_credit(_amount bigint, _kind text, _user uuid, _bet uuid, _match uuid, _reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE new_bal bigint;
BEGIN
  UPDATE virtual_house_wallet SET balance = balance + _amount, total_in = total_in + GREATEST(_amount,0), updated_at = now() WHERE id=1 RETURNING balance INTO new_bal;
  INSERT INTO virtual_house_transactions(kind, amount, balance_after, user_id, bet_id, match_id, actor_id, reason)
    VALUES (_kind, _amount, new_bal, _user, _bet, _match, NULL, _reason);
  RETURN new_bal;
END $$;

CREATE OR REPLACE FUNCTION public.virtual_wallet_debit(_amount bigint, _kind text, _user uuid, _bet uuid, _match uuid, _reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE new_bal bigint; cur bigint;
BEGIN
  SELECT balance INTO cur FROM virtual_house_wallet WHERE id=1 FOR UPDATE;
  IF cur < _amount THEN
    RAISE EXCEPTION 'Virtual wallet has insufficient funds (need %, have %)', _amount, cur USING ERRCODE='P0001';
  END IF;
  UPDATE virtual_house_wallet SET balance = balance - _amount, total_out = total_out + _amount, updated_at = now() WHERE id=1 RETURNING balance INTO new_bal;
  INSERT INTO virtual_house_transactions(kind, amount, balance_after, user_id, bet_id, match_id, actor_id, reason)
    VALUES (_kind, -_amount, new_bal, _user, _bet, _match, NULL, _reason);
  RETURN new_bal;
END $$;

-- 4. Admin funding / adjustment
CREATE OR REPLACE FUNCTION public.virtual_wallet_admin_adjust(_amount bigint, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE new_bal bigint;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF _amount = 0 THEN RAISE EXCEPTION 'Amount must be non-zero'; END IF;
  UPDATE virtual_house_wallet
    SET balance = balance + _amount,
        total_in  = total_in  + GREATEST(_amount, 0),
        total_out = total_out + GREATEST(-_amount, 0),
        updated_at = now()
    WHERE id=1 RETURNING balance INTO new_bal;
  IF new_bal < 0 THEN
    RAISE EXCEPTION 'Adjustment would make wallet negative';
  END IF;
  INSERT INTO virtual_house_transactions(kind, amount, balance_after, actor_id, reason)
    VALUES (CASE WHEN _amount>0 THEN 'admin_fund' ELSE 'admin_debit' END, _amount, new_bal, auth.uid(), _reason);
  RETURN jsonb_build_object('balance', new_bal);
END $$;

-- 5. Route stake -> wallet for single-bet and ticket placement
CREATE OR REPLACE FUNCTION public.place_virtual_bet(_match_id uuid, _odd_id uuid, _stake bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $function$
DECLARE
  uid uuid := auth.uid();
  m record; o record; mk record; p record;
  cfg record;
  payout bigint; new_balance bigint; bet_id uuid; tracking text;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO p FROM profiles WHERE id = uid FOR UPDATE;
  IF p.is_banned OR p.is_restricted THEN RAISE EXCEPTION 'Account cannot place bets'; END IF;

  SELECT * INTO m FROM matches WHERE id = _match_id;
  IF m IS NULL OR NOT m.is_virtual THEN RAISE EXCEPTION 'Round not found'; END IF;
  IF m.status <> 'scheduled' THEN RAISE EXCEPTION 'Round is locked'; END IF;
  IF m.lock_time IS NOT NULL AND m.lock_time <= now() THEN RAISE EXCEPTION 'Round is locked'; END IF;

  SELECT * INTO o FROM odds WHERE id = _odd_id;
  IF o IS NULL THEN RAISE EXCEPTION 'Selection not found'; END IF;
  SELECT * INTO mk FROM markets WHERE id = o.market_id;
  IF mk IS NULL OR mk.match_id <> _match_id OR NOT mk.is_open THEN RAISE EXCEPTION 'Market closed'; END IF;

  SELECT virtual_min_stake, virtual_max_stake, max_payout INTO cfg FROM app_settings WHERE id=1;
  IF _stake < COALESCE(cfg.virtual_min_stake, 100000) THEN RAISE EXCEPTION 'Stake below virtual minimum'; END IF;
  IF _stake > COALESCE(cfg.virtual_max_stake, 10000000) THEN RAISE EXCEPTION 'Stake above virtual maximum'; END IF;
  IF p.token_balance < _stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  payout := LEAST((o.value * _stake)::bigint, COALESCE(cfg.max_payout, 100000000));

  INSERT INTO bets(user_id, stake, total_odds, potential_payout, status)
    VALUES (uid, _stake, o.value, payout, 'open') RETURNING id, tracking_id INTO bet_id, tracking;
  INSERT INTO bet_selections(bet_id, match_id, market_id, odd_id, locked_odds, selection_label)
    VALUES (bet_id, _match_id, mk.id, o.id, o.value, o.label);

  UPDATE profiles SET token_balance = token_balance - _stake WHERE id = uid RETURNING token_balance INTO new_balance;
  -- Route stake into virtual house wallet
  PERFORM public.virtual_wallet_credit(_stake, 'stake', uid, bet_id, _match_id, 'Virtual stake');

  INSERT INTO notifications(user_id, title, body, link)
    VALUES (uid, 'Virtual bet placed', tracking || ' · ' || _stake || ' tokens on ' || o.label, '/ticket/' || bet_id);

  RETURN jsonb_build_object('bet_id', bet_id, 'tracking_id', tracking, 'stake', _stake, 'payout', payout, 'balance', new_balance);
END $function$;

CREATE OR REPLACE FUNCTION public.place_virtual_ticket(_selections jsonb, _stake bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $function$
DECLARE
  uid uuid := auth.uid(); p record; cfg record;
  total_odds numeric := 1; payout bigint; bet_id uuid; tracking text; new_bal bigint;
  s jsonb; o record; mk record; m record;
  first_match uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF jsonb_array_length(_selections) < 1 THEN RAISE EXCEPTION 'No selections'; END IF;
  SELECT * INTO p FROM profiles WHERE id = uid FOR UPDATE;
  IF p.is_banned OR p.is_restricted THEN RAISE EXCEPTION 'Account restricted'; END IF;
  SELECT virtual_min_stake, virtual_max_stake, max_payout INTO cfg FROM app_settings WHERE id=1;
  IF _stake < COALESCE(cfg.virtual_min_stake,100000) THEN RAISE EXCEPTION 'Stake below minimum'; END IF;
  IF _stake > COALESCE(cfg.virtual_max_stake,10000000) THEN RAISE EXCEPTION 'Stake above maximum'; END IF;
  IF p.token_balance < _stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  FOR s IN SELECT * FROM jsonb_array_elements(_selections) LOOP
    SELECT * INTO o FROM odds WHERE id = (s->>'odd_id')::uuid;
    IF o IS NULL THEN RAISE EXCEPTION 'Bad selection'; END IF;
    SELECT * INTO mk FROM markets WHERE id = o.market_id;
    SELECT * INTO m FROM matches WHERE id = mk.match_id;
    IF NOT m.is_virtual THEN RAISE EXCEPTION 'Not virtual'; END IF;
    IF m.status <> 'scheduled' OR (m.lock_time IS NOT NULL AND m.lock_time <= now()) OR NOT mk.is_open THEN
      RAISE EXCEPTION 'Round locked: %', m.name;
    END IF;
    total_odds := total_odds * o.value;
    IF first_match IS NULL THEN first_match := m.id; END IF;
  END LOOP;

  payout := LEAST((total_odds * _stake)::bigint, COALESCE(cfg.max_payout,100000000));
  INSERT INTO bets(user_id, stake, total_odds, potential_payout, status)
    VALUES (uid, _stake, total_odds, payout, 'open') RETURNING id, tracking_id INTO bet_id, tracking;

  FOR s IN SELECT * FROM jsonb_array_elements(_selections) LOOP
    SELECT * INTO o FROM odds WHERE id = (s->>'odd_id')::uuid;
    SELECT * INTO mk FROM markets WHERE id = o.market_id;
    INSERT INTO bet_selections(bet_id, match_id, market_id, odd_id, locked_odds, selection_label)
      VALUES (bet_id, mk.match_id, mk.id, o.id, o.value, o.label);
  END LOOP;

  UPDATE profiles SET token_balance = token_balance - _stake WHERE id=uid RETURNING token_balance INTO new_bal;
  PERFORM public.virtual_wallet_credit(_stake, 'stake', uid, bet_id, first_match, 'Virtual ticket stake');

  INSERT INTO notifications(user_id, title, body, link)
    VALUES (uid, 'Virtual ticket placed', tracking || ' · ' || _stake || ' tokens', '/ticket/' || bet_id);

  RETURN jsonb_build_object('bet_id', bet_id, 'tracking_id', tracking, 'stake', _stake, 'payout', payout, 'balance', new_bal);
END $function$;

-- 6. Approve/decline checks the virtual wallet and reserves funds at approval time
CREATE OR REPLACE FUNCTION public.admin_review_virtual_payout(_id uuid, _approve boolean, _reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; wallet_bal bigint;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO r FROM virtual_payout_requests WHERE id = _id FOR UPDATE;
  IF r IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  IF r.status <> 'pending' THEN RAISE EXCEPTION 'Already reviewed'; END IF;
  IF _approve THEN
    SELECT balance INTO wallet_bal FROM virtual_house_wallet WHERE id=1;
    IF wallet_bal < r.amount THEN
      RAISE EXCEPTION 'Virtual wallet underfunded: need %, have %', r.amount, wallet_bal;
    END IF;
    UPDATE virtual_payout_requests SET status='approved', reviewed_by=auth.uid(), reviewed_at=now() WHERE id=_id;
    INSERT INTO notifications(user_id, title, body, link)
      VALUES (r.user_id, 'Virtual win approved', 'Your payout of '|| r.amount ||' tokens is ready to claim.', '/virtual/history');
  ELSE
    UPDATE virtual_payout_requests SET status='declined', decline_reason=_reason, reviewed_by=auth.uid(), reviewed_at=now() WHERE id=_id;
    INSERT INTO notifications(user_id, title, body, link)
      VALUES (r.user_id, 'Virtual win declined', COALESCE(_reason,'No reason provided'), '/virtual/history');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- 7. Claim debits from virtual wallet
CREATE OR REPLACE FUNCTION public.claim_virtual_payout(_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; new_bal bigint;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO r FROM virtual_payout_requests WHERE id = _id FOR UPDATE;
  IF r IS NULL OR r.user_id <> auth.uid() THEN RAISE EXCEPTION 'Not yours'; END IF;
  IF r.status <> 'approved' THEN RAISE EXCEPTION 'Not approved'; END IF;
  -- Debit virtual wallet (will throw if insufficient)
  PERFORM public.virtual_wallet_debit(r.amount, 'payout', r.user_id, r.bet_id, r.match_id, 'Virtual payout claim');
  UPDATE profiles SET token_balance = token_balance + r.amount,
      xp = xp + COALESCE((SELECT virtual_xp_per_win FROM app_settings WHERE id=1),0)
    WHERE id = auth.uid() RETURNING token_balance INTO new_bal;
  INSERT INTO token_transactions(user_id, amount, balance_after, kind, description)
    VALUES (auth.uid(), r.amount, new_bal, 'bet_win', 'Virtual claim');
  UPDATE virtual_payout_requests SET status='claimed', claimed_at=now() WHERE id=_id;
  RETURN jsonb_build_object('ok', true, 'amount', r.amount, 'balance', new_bal);
END $$;

-- 8. Tick: maintain N concurrent rounds + sweep open bets
CREATE OR REPLACE FUNCTION public.virtual_tick()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $function$
DECLARE
  cfg record; m record; anim_sec int; dur_sec int;
  active_count int; target_n int;
  t1 uuid; t2 uuid; new_match_id uuid; market_id uuid;
  team_a_name text; team_b_name text;
  locked_n int := 0; resolved_n int := 0; spawned int := 0; swept int := 0;
  elapsed numeric; tgt_h int; tgt_a int; max_s int;
  i int;
BEGIN
  SELECT virtual_cycle_running, virtual_round_duration_seconds, virtual_animation_seconds, virtual_max_score, virtual_concurrent_rounds
    INTO cfg FROM app_settings WHERE id=1;
  dur_sec := COALESCE(cfg.virtual_round_duration_seconds, 120);
  anim_sec := COALESCE(cfg.virtual_animation_seconds, 30);
  max_s := COALESCE(cfg.virtual_max_score, 8);
  target_n := GREATEST(COALESCE(cfg.virtual_concurrent_rounds, 4), 1);

  -- Lock matches whose lock_time has passed
  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='scheduled' AND lock_time IS NOT NULL AND lock_time <= now()
  LOOP
    UPDATE matches SET status='live', locked_at=COALESCE(locked_at,now()), updated_at=now() WHERE id=m.id;
    UPDATE markets SET is_open=false WHERE match_id=m.id;
    locked_n := locked_n + 1;
  END LOOP;

  -- Progressive scores during live window
  FOR m IN SELECT id, lock_time, home_score, away_score FROM matches
    WHERE is_virtual=true AND status='live' AND lock_time IS NOT NULL
      AND lock_time + (anim_sec || ' seconds')::interval > now()
  LOOP
    elapsed := EXTRACT(EPOCH FROM (now() - m.lock_time)) / GREATEST(anim_sec, 1);
    elapsed := LEAST(GREATEST(elapsed, 0), 0.95);
    tgt_h := (abs(hashtext(m.id::text || ':h')) % (max_s + 1));
    tgt_a := (abs(hashtext(m.id::text || ':a')) % (max_s + 1));
    UPDATE matches SET
      home_score = GREATEST(home_score, floor(tgt_h * elapsed)::int),
      away_score = GREATEST(away_score, floor(tgt_a * elapsed)::int),
      updated_at = now() WHERE id = m.id;
  END LOOP;

  -- Resolve ended rounds
  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='live' AND lock_time IS NOT NULL AND lock_time + (anim_sec || ' seconds')::interval <= now()
  LOOP
    PERFORM public.auto_resolve_virtual_round(m.id);
    resolved_n := resolved_n + 1;
  END LOOP;

  -- Sweep: settle any remaining open bets whose virtual selections are all done
  WITH affected AS (
    SELECT DISTINCT b.id AS bet_id
    FROM bets b
    JOIN bet_selections bs ON bs.bet_id = b.id
    JOIN matches m2 ON m2.id = bs.match_id
    WHERE b.status='open' AND m2.is_virtual=true
  ),
  bet_status AS (
    SELECT b.id AS bet_id,
      bool_or(o.is_winner IS FALSE AND o.is_winner IS NOT NULL AND m2.status='ended') AS has_loser,
      bool_and(o.is_winner IS TRUE) AS all_winners,
      count(*) FILTER (WHERE m2.status <> 'ended') AS unsettled
    FROM bets b
    JOIN bet_selections bs ON bs.bet_id = b.id
    JOIN odds o ON o.id = bs.odd_id
    JOIN matches m2 ON m2.id = bs.match_id
    WHERE b.id IN (SELECT bet_id FROM affected) AND b.status='open'
    GROUP BY b.id
  ),
  upd AS (
    UPDATE bets b SET
      status = CASE WHEN bs.has_loser THEN 'lost'::bet_status
                    WHEN bs.all_winners AND bs.unsettled=0 THEN 'won'::bet_status
                    ELSE b.status END,
      settled_at = CASE WHEN bs.has_loser OR (bs.all_winners AND bs.unsettled=0) THEN now() ELSE b.settled_at END
    FROM bet_status bs WHERE b.id = bs.bet_id
      AND (bs.has_loser OR (bs.all_winners AND bs.unsettled=0))
    RETURNING b.id
  )
  SELECT count(*) INTO swept FROM upd;

  UPDATE app_settings SET virtual_cycle_last_tick = now() WHERE id=1;

  -- Spawn until target_n concurrent rounds are alive
  IF cfg.virtual_cycle_running THEN
    SELECT count(*) INTO active_count FROM matches
      WHERE is_virtual=true AND status IN ('scheduled','live');
    i := 0;
    WHILE active_count + i < target_n LOOP
      SELECT id INTO t1 FROM teams ORDER BY random() LIMIT 1;
      SELECT id INTO t2 FROM teams WHERE id <> t1 ORDER BY random() LIMIT 1;
      IF t1 IS NULL OR t2 IS NULL THEN EXIT; END IF;
      SELECT name INTO team_a_name FROM teams WHERE id=t1;
      SELECT name INTO team_b_name FROM teams WHERE id=t2;
      INSERT INTO matches(name, home_team_id, away_team_id, start_time, lock_time, status, is_virtual, is_featured)
        VALUES (team_a_name || ' vs ' || team_b_name, t1, t2, now(), now() + (dur_sec || ' seconds')::interval, 'scheduled', true, false)
        RETURNING id INTO new_match_id;
      INSERT INTO markets(match_id, name, is_open) VALUES (new_match_id, 'Match Winner', true) RETURNING id INTO market_id;
      INSERT INTO odds(market_id, label, value) VALUES
        (market_id, team_a_name, round((1.6 + random()*1.4)::numeric,2)),
        (market_id, 'Draw', round((3.0 + random()*1.5)::numeric,2)),
        (market_id, team_b_name, round((1.6 + random()*1.4)::numeric,2));
      INSERT INTO markets(match_id, name, is_open) VALUES (new_match_id, 'First Blood', true) RETURNING id INTO market_id;
      INSERT INTO odds(market_id, label, value) VALUES
        (market_id, team_a_name, round((1.7 + random()*0.4)::numeric,2)),
        (market_id, team_b_name, round((1.7 + random()*0.4)::numeric,2));
      INSERT INTO markets(match_id, name, is_open) VALUES (new_match_id, 'Total Kills', true) RETURNING id INTO market_id;
      INSERT INTO odds(market_id, label, value) VALUES
        (market_id, 'Over 4.5', round((1.8 + random()*0.4)::numeric,2)),
        (market_id, 'Under 4.5', round((1.8 + random()*0.4)::numeric,2));
      INSERT INTO markets(match_id, name, is_open) VALUES (new_match_id, 'Correct Score', true) RETURNING id INTO market_id;
      INSERT INTO odds(market_id, label, value) VALUES
        (market_id, '1:0', 6.5),(market_id,'2:0',9.0),(market_id,'2:1',8.0),
        (market_id, '0:1', 6.5),(market_id,'0:2',9.0),(market_id,'1:2',8.0),
        (market_id, '1:1', 5.5),(market_id,'2:2',12.0),(market_id,'3:1',14.0),
        (market_id, '1:3', 14.0),(market_id,'0:0',8.0),(market_id,'3:0',16.0);
      spawned := spawned + 1;
      i := i + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('locked', locked_n, 'resolved', resolved_n, 'spawned', spawned, 'swept', swept, 'cycle', cfg.virtual_cycle_running, 'target', target_n);
END $function$;
