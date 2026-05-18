
CREATE OR REPLACE FUNCTION public.place_virtual_bet(_match_id uuid, _odd_id uuid, _stake bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    SELECT 1 FROM bets b JOIN bet_selections bs ON bs.bet_id = b.id
    WHERE b.user_id = uid AND bs.match_id = _match_id AND b.status = 'open'
  ) THEN
    RAISE EXCEPTION 'You already have an active bet on this round';
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
END $function$;

CREATE OR REPLACE FUNCTION public.place_virtual_ticket(_selections jsonb, _stake bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      SELECT 1 FROM bets b JOIN bet_selections bs ON bs.bet_id = b.id
      WHERE b.user_id = uid AND bs.match_id = mid AND b.status = 'open'
    ) THEN
      RAISE EXCEPTION 'You already have an active bet on one of these rounds';
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
END $function$;
