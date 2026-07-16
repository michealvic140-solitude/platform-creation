
-- 1) virtual_tick: no longer auto-promotes scheduled -> live on lock_time.
--    Live rounds still resolve when their animation window elapses, and the
--    cycle still spawns a fresh batch when no matches are active.
CREATE OR REPLACE FUNCTION public.virtual_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  cfg record;
  dur_sec integer;
  anim_sec integer;
  match_count integer;
  active_count integer;
  live_row record;
  team_a record;
  team_b record;
  cat_id uuid;
  batch_id uuid;
  new_match_id uuid;
  mk_id uuid;
  h int;
  a int;
  max_market_score int;
  spawned integer := 0;
  resolved integer := 0;
BEGIN
  SELECT COALESCE(virtual_cycle_running, false) AS running,
         GREATEST(10, COALESCE(virtual_round_duration_seconds, 120)) AS dur,
         GREATEST(8, COALESCE(virtual_animation_seconds, 30)) AS anim,
         GREATEST(4, LEAST(6, COALESCE(virtual_matches_per_round, virtual_concurrent_rounds, 5))) AS per_round,
         LEAST(7, GREATEST(5, COALESCE(virtual_max_score, 8))) AS market_score
    INTO cfg FROM public.app_settings WHERE id = 1;

  UPDATE public.app_settings SET virtual_cycle_last_tick = now() WHERE id = 1;
  dur_sec := cfg.dur;
  anim_sec := cfg.anim;
  match_count := cfg.per_round;
  max_market_score := cfg.market_score;

  -- Resolve live rounds once their animation window elapses.
  FOR live_row IN
    SELECT id FROM public.matches
     WHERE is_virtual = true AND status = 'live'
       AND COALESCE(locked_at, lock_time, start_time, created_at, now()) + (anim_sec || ' seconds')::interval <= now()
     ORDER BY COALESCE(locked_at, lock_time, start_time, created_at) ASC LIMIT 100
  LOOP
    PERFORM public.resolve_virtual_round(live_row.id, NULL, NULL, NULL);
    resolved := resolved + 1;
  END LOOP;

  IF NOT cfg.running THEN
    RETURN jsonb_build_object('ok', true, 'running', false, 'spawned', 0, 'promoted', 0, 'resolved', resolved);
  END IF;

  SELECT COUNT(*) INTO active_count FROM public.matches WHERE is_virtual = true AND status IN ('scheduled', 'live');

  IF active_count = 0 THEN
    batch_id := gen_random_uuid();
    WHILE spawned < match_count LOOP
      SELECT id, name INTO team_a FROM public.teams ORDER BY random() LIMIT 1;
      SELECT id, name INTO team_b FROM public.teams WHERE id <> team_a.id ORDER BY random() LIMIT 1;
      EXIT WHEN team_a.id IS NULL OR team_b.id IS NULL;
      SELECT id INTO cat_id FROM public.categories WHERE name = 'Virtual Gangs' LIMIT 1;
      IF cat_id IS NULL THEN INSERT INTO public.categories (name, icon) VALUES ('Virtual Gangs', '🎲') RETURNING id INTO cat_id; END IF;

      -- lock_time set far in the future; it is now decorative — stakes drive kickoff.
      INSERT INTO public.matches (name, home_team_id, away_team_id, category_id, status, is_virtual, start_time, lock_time, virtual_round_batch_id, virtual_round_id, home_score, away_score)
        VALUES (team_a.name || ' vs ' || team_b.name, team_a.id, team_b.id, cat_id, 'scheduled', true, now(), now() + interval '365 days', batch_id, batch_id, 0, 0)
        RETURNING id INTO new_match_id;
      INSERT INTO public.markets (match_id, name, is_open) VALUES (new_match_id, 'Match Winner', true) RETURNING id INTO mk_id;
      INSERT INTO public.odds (market_id, label, value) VALUES (mk_id, team_a.name, 1.95), (mk_id, 'Draw', 3.40), (mk_id, team_b.name, 1.95);
      INSERT INTO public.markets (match_id, name, is_open) VALUES (new_match_id, 'First Blood', true) RETURNING id INTO mk_id;
      INSERT INTO public.odds (market_id, label, value) VALUES (mk_id, team_a.name, 1.95), (mk_id, team_b.name, 1.95);
      INSERT INTO public.markets (match_id, name, is_open) VALUES (new_match_id, 'Total Kills O/U 4.5', true) RETURNING id INTO mk_id;
      INSERT INTO public.odds (market_id, label, value) VALUES (mk_id, 'Over 4.5', 1.85), (mk_id, 'Under 4.5', 1.85);
      INSERT INTO public.markets (match_id, name, is_open) VALUES (new_match_id, 'Correct Score', true) RETURNING id INTO mk_id;
      FOR h IN 0..max_market_score LOOP
        FOR a IN 0..max_market_score LOOP
          INSERT INTO public.odds (market_id, label, value) VALUES (mk_id, h::text || ':' || a::text, 8.50);
        END LOOP;
      END LOOP;
      spawned := spawned + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'running', true, 'spawned', spawned, 'promoted', 0, 'resolved', resolved, 'active_count', active_count, 'matches_per_round', match_count, 'round_seconds', dur_sec, 'animation_seconds', anim_sec);
END;
$function$;

-- 2) place_virtual_ticket: drop the "lock_time in the past" rejection and,
--    once selections are recorded, kick off every match in that batch
--    immediately for all users (scores seeded, markets closed, status live).
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
  first_match uuid; sel_count int; cap bigint;
  kick_batch uuid; kick_row record; planned record;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  sel_count := jsonb_array_length(_selections);
  SELECT * INTO p FROM public.profiles WHERE id = uid FOR UPDATE;
  IF p.is_banned OR p.is_restricted THEN RAISE EXCEPTION 'Account restricted'; END IF;
  SELECT virtual_min_stake, virtual_max_stake, max_payout, virtual_max_payout, virtual_min_selections, virtual_max_selections INTO cfg FROM public.app_settings WHERE id=1;
  IF sel_count < COALESCE(cfg.virtual_min_selections,1) THEN RAISE EXCEPTION 'Minimum % selections required', COALESCE(cfg.virtual_min_selections,1); END IF;
  IF sel_count > COALESCE(cfg.virtual_max_selections,20) THEN RAISE EXCEPTION 'Maximum % selections allowed', COALESCE(cfg.virtual_max_selections,20); END IF;
  IF _stake < COALESCE(cfg.virtual_min_stake,100000) THEN RAISE EXCEPTION 'Stake below minimum'; END IF;
  IF p.token_balance < _stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  FOR s IN SELECT * FROM jsonb_array_elements(_selections) LOOP
    SELECT * INTO o FROM public.odds WHERE id = (s->>'odd_id')::uuid;
    IF o IS NULL THEN RAISE EXCEPTION 'Bad selection'; END IF;
    SELECT * INTO mk FROM public.markets WHERE id = o.market_id;
    SELECT * INTO m FROM public.matches WHERE id = mk.match_id;
    IF NOT m.is_virtual THEN RAISE EXCEPTION 'Not virtual'; END IF;
    IF lower(mk.name) NOT LIKE '%match winner%' AND lower(mk.name) NOT LIKE '%win / draw / lose%' AND lower(mk.name) NOT LIKE '%first blood%' THEN
      RAISE EXCEPTION 'This virtual market is closed';
    END IF;
    -- Kickoff is user-driven now; only reject if the round has already been played.
    IF m.status <> 'scheduled' OR NOT mk.is_open THEN
      RAISE EXCEPTION 'Round locked: %', m.name;
    END IF;
    total_odds := total_odds * o.value;
    IF first_match IS NULL THEN first_match := m.id; END IF;
  END LOOP;

  cap := COALESCE(NULLIF(cfg.virtual_max_payout, 0), cfg.max_payout, 100000000);
  payout := LEAST((total_odds * _stake)::bigint, cap);

  INSERT INTO public.bets(user_id, stake, total_odds, potential_payout, status, is_virtual, kind)
    VALUES (uid, _stake, total_odds, payout, 'open', true, 'virtual_sports')
    RETURNING id, tracking_id INTO bet_id, tracking;
  FOR s IN SELECT * FROM jsonb_array_elements(_selections) LOOP
    SELECT * INTO o FROM public.odds WHERE id = (s->>'odd_id')::uuid;
    SELECT * INTO mk FROM public.markets WHERE id = o.market_id;
    INSERT INTO public.bet_selections(bet_id, match_id, market_id, odd_id, locked_odds, selection_label)
      VALUES (bet_id, mk.match_id, mk.id, o.id, o.value, o.label);
  END LOOP;
  UPDATE public.profiles SET token_balance = token_balance - _stake WHERE id=uid RETURNING token_balance INTO new_bal;
  PERFORM public.virtual_wallet_credit(_stake, 'stake', uid, bet_id, first_match, 'Virtual ticket stake');
  INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (uid, 'Virtual ticket placed', tracking || ' - ' || _stake || ' tokens', '/ticket/' || bet_id);

  -- Kick off the entire batch immediately. Every match in the same
  -- virtual_round_batch_id (or the staked match alone if it has no batch)
  -- flips to live right now.
  SELECT virtual_round_batch_id INTO kick_batch FROM public.matches WHERE id = first_match;
  FOR kick_row IN
    SELECT id FROM public.matches
     WHERE is_virtual = true
       AND status = 'scheduled'
       AND (
         (kick_batch IS NOT NULL AND virtual_round_batch_id = kick_batch)
         OR (kick_batch IS NULL AND id = first_match)
       )
  LOOP
    SELECT * INTO planned FROM public.virtual_score_for_match(kick_row.id);
    UPDATE public.matches
       SET status = 'live',
           lock_time = now(),
           locked_at = now(),
           locked_by = uid,
           home_score = planned.home_score,
           away_score = planned.away_score,
           virtual_first_blood_team_id = planned.first_blood_team_id,
           updated_at = now()
     WHERE id = kick_row.id;
    UPDATE public.markets SET is_open = false WHERE match_id = kick_row.id;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'bet_id', bet_id, 'tracking_id', tracking, 'payout', payout, 'new_balance', new_bal);
END;
$function$;
