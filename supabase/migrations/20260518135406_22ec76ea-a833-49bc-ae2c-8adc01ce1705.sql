CREATE OR REPLACE FUNCTION public.place_virtual_bet(_match_id uuid, _odd_id uuid, _stake bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  uid uuid := auth.uid();
  m record; o record; mk record; p record;
  cfg record; cap bigint;
  payout bigint; new_balance bigint; bet_id uuid; tracking text;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO p FROM profiles WHERE id = uid FOR UPDATE;
  IF p.is_banned OR p.is_restricted THEN RAISE EXCEPTION 'Account cannot place bets'; END IF;

  SELECT * INTO m FROM matches WHERE id = _match_id;
  IF m IS NULL OR NOT m.is_virtual THEN RAISE EXCEPTION 'Round not found'; END IF;
  IF m.status <> 'scheduled' THEN RAISE EXCEPTION 'Round is locked'; END IF;
  IF m.lock_time IS NOT NULL AND m.lock_time <= now() THEN RAISE EXCEPTION 'Round is locked'; END IF;

  IF EXISTS (
    SELECT 1
    FROM bets b
    JOIN bet_selections bs ON bs.bet_id = b.id
    WHERE b.user_id = uid
      AND bs.match_id = _match_id
      AND b.status IN ('open','won','lost','suspended')
  ) THEN
    RAISE EXCEPTION 'You already staked this virtual round';
  END IF;

  SELECT * INTO o FROM odds WHERE id = _odd_id;
  IF o IS NULL THEN RAISE EXCEPTION 'Selection not found'; END IF;
  SELECT * INTO mk FROM markets WHERE id = o.market_id;
  IF mk IS NULL OR mk.match_id <> _match_id OR NOT mk.is_open THEN RAISE EXCEPTION 'Market closed'; END IF;

  SELECT virtual_min_stake, virtual_max_stake, max_payout, virtual_max_payout, virtual_min_selections INTO cfg FROM app_settings WHERE id=1;
  IF COALESCE(cfg.virtual_min_selections,1) > 1 THEN RAISE EXCEPTION 'Minimum % selections required', cfg.virtual_min_selections; END IF;
  IF _stake < COALESCE(cfg.virtual_min_stake, 100000) THEN RAISE EXCEPTION 'Stake below virtual minimum'; END IF;
  IF _stake > COALESCE(cfg.virtual_max_stake, 10000000) THEN RAISE EXCEPTION 'Stake above virtual maximum'; END IF;
  IF p.token_balance < _stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  cap := COALESCE(cfg.virtual_max_payout, cfg.max_payout, 100000000);
  payout := LEAST((o.value * _stake)::bigint, cap);

  INSERT INTO bets(user_id, stake, total_odds, potential_payout, status)
    VALUES (uid, _stake, o.value, payout, 'open') RETURNING id, tracking_id INTO bet_id, tracking;
  INSERT INTO bet_selections(bet_id, match_id, market_id, odd_id, locked_odds, selection_label)
    VALUES (bet_id, _match_id, mk.id, o.id, o.value, o.label);

  UPDATE profiles SET token_balance = token_balance - _stake WHERE id = uid RETURNING token_balance INTO new_balance;
  PERFORM public.virtual_wallet_credit(_stake, 'stake', uid, bet_id, _match_id, 'Virtual stake');

  INSERT INTO notifications(user_id, title, body, link)
    VALUES (uid, 'Virtual bet placed', tracking || ' · ' || _stake || ' tokens on ' || o.label, '/ticket/' || bet_id);

  RETURN jsonb_build_object('bet_id', bet_id, 'tracking_id', tracking, 'stake', _stake, 'payout', payout, 'balance', new_balance);
END $$;

CREATE OR REPLACE FUNCTION public.place_virtual_ticket(_selections jsonb, _stake bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  uid uuid := auth.uid(); p record; cfg record;
  total_odds numeric := 1; payout bigint; bet_id uuid; tracking text; new_bal bigint;
  s jsonb; o record; mk record; m record;
  first_match uuid;
  sel_count int;
  cap bigint;
  match_ids uuid[] := '{}';
  mid uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  sel_count := jsonb_array_length(_selections);
  SELECT * INTO p FROM profiles WHERE id = uid FOR UPDATE;
  IF p.is_banned OR p.is_restricted THEN RAISE EXCEPTION 'Account restricted'; END IF;
  SELECT virtual_min_stake, virtual_max_stake, max_payout, virtual_max_payout, virtual_min_selections, virtual_max_selections INTO cfg FROM app_settings WHERE id=1;
  IF sel_count < COALESCE(cfg.virtual_min_selections,1) THEN RAISE EXCEPTION 'Minimum % selections required', COALESCE(cfg.virtual_min_selections,1); END IF;
  IF sel_count > COALESCE(cfg.virtual_max_selections,20) THEN RAISE EXCEPTION 'Maximum % selections allowed', COALESCE(cfg.virtual_max_selections,20); END IF;
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
    IF m.id = ANY(match_ids) THEN
      RAISE EXCEPTION 'You cannot pick the same round twice on one ticket: %', m.name;
    END IF;
    match_ids := array_append(match_ids, m.id);
    total_odds := total_odds * o.value;
    IF first_match IS NULL THEN first_match := m.id; END IF;
  END LOOP;

  FOREACH mid IN ARRAY match_ids LOOP
    IF EXISTS (
      SELECT 1
      FROM bets b
      JOIN bet_selections bs ON bs.bet_id = b.id
      WHERE b.user_id = uid
        AND bs.match_id = mid
        AND b.status IN ('open','won','lost','suspended')
    ) THEN
      RAISE EXCEPTION 'You already staked one of these virtual rounds';
    END IF;
  END LOOP;

  cap := COALESCE(cfg.virtual_max_payout, cfg.max_payout, 100000000);
  payout := LEAST((total_odds * _stake)::bigint, cap);
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
END $$;

CREATE OR REPLACE FUNCTION public.virtual_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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

  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='scheduled' AND lock_time IS NOT NULL AND lock_time <= now()
  LOOP
    UPDATE matches SET status='live', locked_at=COALESCE(locked_at,now()), updated_at=now() WHERE id=m.id;
    UPDATE markets SET is_open=false WHERE match_id=m.id;
    locked_n := locked_n + 1;
  END LOOP;

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

  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='live' AND lock_time IS NOT NULL AND lock_time + (anim_sec || ' seconds')::interval <= now()
  LOOP
    PERFORM public.auto_resolve_virtual_round(m.id);
    resolved_n := resolved_n + 1;
  END LOOP;

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
        VALUES (team_a_name || ' vs ' || team_b_name, t1, t2, now() + (dur_sec || ' seconds')::interval, now() + (dur_sec || ' seconds')::interval, 'scheduled', true, false)
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
END $$;

GRANT EXECUTE ON FUNCTION public.place_virtual_bet(uuid, uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_virtual_ticket(jsonb, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.virtual_tick() TO anon, authenticated;