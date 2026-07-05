CREATE OR REPLACE FUNCTION public.admin_set_virtual_cycle(_running boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  tick_result jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.app_settings
     SET virtual_cycle_running = _running,
         updated_at = now()
   WHERE id = 1;

  INSERT INTO public.audit_logs(actor_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    CASE WHEN _running THEN 'virtual_cycle_started' ELSE 'virtual_cycle_paused' END,
    'cycle',
    '1',
    jsonb_build_object('at', now())
  );

  IF _running THEN
    tick_result := public.virtual_tick();
  END IF;

  RETURN jsonb_build_object('ok', true, 'running', _running, 'tick', tick_result);
END;
$$;

CREATE OR REPLACE FUNCTION public.virtual_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  cfg record;
  m record;
  anim_sec int;
  dur_sec int;
  active_count int;
  per_round int;
  t1 uuid;
  t2 uuid;
  new_match_id uuid;
  market_id uuid;
  team_a_name text;
  team_b_name text;
  locked_n int := 0;
  resolved_n int := 0;
  spawned int := 0;
  swept int := 0;
  elapsed numeric;
  tgt_h int;
  tgt_a int;
  max_s int;
  batch_id uuid;
  i int;
  cat_id uuid;
BEGIN
  SELECT
    COALESCE(virtual_cycle_running, false) AS virtual_cycle_running,
    GREATEST(30, COALESCE(virtual_round_duration_seconds, 120)) AS virtual_round_duration_seconds,
    GREATEST(12, COALESCE(virtual_animation_seconds, 30)) AS virtual_animation_seconds,
    GREATEST(1, LEAST(10, COALESCE(virtual_matches_per_round, virtual_concurrent_rounds, 5))) AS virtual_matches_per_round,
    GREATEST(1, LEAST(12, COALESCE(virtual_max_score, 8))) AS virtual_max_score
    INTO cfg
  FROM public.app_settings
  WHERE id = 1;

  dur_sec := COALESCE(cfg.virtual_round_duration_seconds, 120);
  anim_sec := COALESCE(cfg.virtual_animation_seconds, 30);
  max_s := COALESCE(cfg.virtual_max_score, 8);
  per_round := COALESCE(cfg.virtual_matches_per_round, 5);

  -- Lock every open virtual match whose betting countdown has expired.
  FOR m IN
    SELECT id, COALESCE(lock_time, start_time, created_at, now()) AS lock_at
      FROM public.matches
     WHERE is_virtual = true
       AND status = 'scheduled'
       AND COALESCE(lock_time, start_time, created_at, now()) <= now()
     ORDER BY COALESCE(lock_time, start_time, created_at) ASC
     LIMIT 100
  LOOP
    tgt_h := abs(hashtext(m.id::text || ':h')) % (max_s + 1);
    tgt_a := abs(hashtext(m.id::text || ':a')) % (max_s + 1);
    IF tgt_h = 0 AND tgt_a = 0 THEN
      tgt_h := 1;
    END IF;

    UPDATE public.matches
       SET status = 'live',
           locked_at = COALESCE(locked_at, m.lock_at, now()),
           -- Store the final target at lock time so the UI can animate toward a real non-dormant score.
           home_score = tgt_h,
           away_score = tgt_a,
           updated_at = now()
     WHERE id = m.id;

    UPDATE public.markets SET is_open = false WHERE match_id = m.id;
    locked_n := locked_n + 1;
  END LOOP;

  -- Keep live rows fresh so side scoreboards and other clients move during the shootout window.
  FOR m IN
    SELECT id, COALESCE(locked_at, lock_time, start_time, created_at, now()) AS lock_at, home_score, away_score
      FROM public.matches
     WHERE is_virtual = true
       AND status = 'live'
       AND COALESCE(locked_at, lock_time, start_time, created_at, now()) + (anim_sec || ' seconds')::interval > now()
     ORDER BY COALESCE(locked_at, lock_time, start_time, created_at) ASC
     LIMIT 100
  LOOP
    elapsed := EXTRACT(EPOCH FROM (now() - m.lock_at)) / GREATEST(anim_sec, 1);
    elapsed := LEAST(GREATEST(elapsed, 0), 0.98);

    UPDATE public.matches
       SET updated_at = now()
     WHERE id = m.id;
  END LOOP;

  -- Resolve every live match once the shootout animation has completed.
  FOR m IN
    SELECT id
      FROM public.matches
     WHERE is_virtual = true
       AND status = 'live'
       AND COALESCE(locked_at, lock_time, start_time, created_at, now()) + (anim_sec || ' seconds')::interval <= now()
     ORDER BY COALESCE(locked_at, lock_time, start_time, created_at) ASC
     LIMIT 100
  LOOP
    PERFORM public.auto_resolve_virtual_round(m.id);
    resolved_n := resolved_n + 1;
  END LOOP;

  -- Sweep tickets touching virtual matches in case a previous tick stopped after resolving odds.
  WITH affected AS (
    SELECT DISTINCT b.id AS bet_id
      FROM public.bets b
      JOIN public.bet_selections bs ON bs.bet_id = b.id
      JOIN public.matches m2 ON m2.id = bs.match_id
     WHERE b.status = 'open'
       AND m2.is_virtual = true
  ),
  bet_status AS (
    SELECT b.id AS bet_id,
           bool_or(o.is_winner IS FALSE AND o.is_winner IS NOT NULL AND m2.status = 'ended') AS has_loser,
           bool_and(o.is_winner IS TRUE) AS all_winners,
           count(*) FILTER (WHERE m2.status <> 'ended') AS unsettled
      FROM public.bets b
      JOIN public.bet_selections bs ON bs.bet_id = b.id
      JOIN public.odds o ON o.id = bs.odd_id
      JOIN public.matches m2 ON m2.id = bs.match_id
     WHERE b.id IN (SELECT bet_id FROM affected)
       AND b.status = 'open'
     GROUP BY b.id
  ),
  upd AS (
    UPDATE public.bets b
       SET status = CASE
             WHEN bs.has_loser THEN 'lost'::bet_status
             WHEN bs.all_winners AND bs.unsettled = 0 THEN 'won'::bet_status
             ELSE b.status
           END,
           settled_at = CASE
             WHEN bs.has_loser OR (bs.all_winners AND bs.unsettled = 0) THEN now()
             ELSE b.settled_at
           END
      FROM bet_status bs
     WHERE b.id = bs.bet_id
       AND (bs.has_loser OR (bs.all_winners AND bs.unsettled = 0))
     RETURNING b.id
  )
  SELECT count(*) INTO swept FROM upd;

  UPDATE public.app_settings
     SET virtual_cycle_last_tick = now()
   WHERE id = 1;

  -- Spawn the next full batch when the cycle is running and no active virtual matches remain.
  IF cfg.virtual_cycle_running THEN
    SELECT count(*) INTO active_count
      FROM public.matches
     WHERE is_virtual = true
       AND status IN ('scheduled', 'live');

    IF active_count = 0 THEN
      SELECT id INTO cat_id FROM public.categories WHERE name = 'Virtual Gangs' LIMIT 1;
      IF cat_id IS NULL THEN
        INSERT INTO public.categories(name, icon) VALUES ('Virtual Gangs', '🎯') RETURNING id INTO cat_id;
      END IF;

      batch_id := gen_random_uuid();
      FOR i IN 1..per_round LOOP
        SELECT id, name INTO t1, team_a_name FROM public.teams ORDER BY random() LIMIT 1;
        SELECT id, name INTO t2, team_b_name FROM public.teams WHERE id <> t1 ORDER BY random() LIMIT 1;
        IF t1 IS NULL OR t2 IS NULL THEN
          EXIT;
        END IF;

        INSERT INTO public.matches(
          name, home_team_id, away_team_id, category_id, start_time, lock_time,
          status, is_virtual, is_featured, virtual_round_batch_id, virtual_round_id,
          home_score, away_score, match_kind
        ) VALUES (
          team_a_name || ' vs ' || team_b_name,
          t1,
          t2,
          cat_id,
          now(),
          now() + (dur_sec || ' seconds')::interval,
          'scheduled',
          true,
          false,
          batch_id,
          batch_id,
          0,
          0,
          'gang'
        ) RETURNING id INTO new_match_id;

        INSERT INTO public.markets(match_id, name, is_open)
        VALUES (new_match_id, 'Match Winner', true)
        RETURNING id INTO market_id;
        INSERT INTO public.odds(market_id, label, value) VALUES
          (market_id, team_a_name, round((1.55 + random() * 1.45)::numeric, 2)),
          (market_id, 'Draw', round((3.00 + random() * 1.75)::numeric, 2)),
          (market_id, team_b_name, round((1.55 + random() * 1.45)::numeric, 2));

        INSERT INTO public.markets(match_id, name, is_open)
        VALUES (new_match_id, 'First Blood', true)
        RETURNING id INTO market_id;
        INSERT INTO public.odds(market_id, label, value) VALUES
          (market_id, team_a_name, round((1.70 + random() * 0.45)::numeric, 2)),
          (market_id, team_b_name, round((1.70 + random() * 0.45)::numeric, 2));

        INSERT INTO public.markets(match_id, name, is_open)
        VALUES (new_match_id, 'Total Kills O/U 4.5', true)
        RETURNING id INTO market_id;
        INSERT INTO public.odds(market_id, label, value) VALUES
          (market_id, 'Over 4.5', round((1.75 + random() * 0.45)::numeric, 2)),
          (market_id, 'Under 4.5', round((1.75 + random() * 0.45)::numeric, 2));

        spawned := spawned + 1;
      END LOOP;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'locked', locked_n,
    'resolved', resolved_n,
    'spawned', spawned,
    'swept', swept,
    'cycle', cfg.virtual_cycle_running,
    'per_round', per_round,
    'round_seconds', dur_sec,
    'animation_seconds', anim_sec
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_virtual_cycle(boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.virtual_tick() TO anon, authenticated, service_role;

UPDATE public.app_settings
   SET virtual_cycle_running = true,
       virtual_round_duration_seconds = GREATEST(30, COALESCE(virtual_round_duration_seconds, 120)),
       virtual_animation_seconds = GREATEST(12, COALESCE(virtual_animation_seconds, 30)),
       updated_at = now()
 WHERE id = 1;

SELECT public.virtual_tick();