CREATE OR REPLACE FUNCTION public.virtual_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  cfg record; m record; anim_sec int; dur_sec int;
  active_count int; per_round int;
  t1 uuid; t2 uuid; new_match_id uuid; market_id uuid;
  team_a_name text; team_b_name text;
  locked_n int := 0; resolved_n int := 0; spawned int := 0; swept int := 0;
  elapsed numeric; tgt_h int; tgt_a int; max_s int;
  batch_id uuid;
  i int;
BEGIN
  SELECT virtual_cycle_running, virtual_round_duration_seconds, virtual_animation_seconds,
         virtual_max_score, virtual_matches_per_round, virtual_concurrent_rounds
    INTO cfg FROM app_settings WHERE id=1;
  dur_sec := COALESCE(cfg.virtual_round_duration_seconds, 120);
  anim_sec := COALESCE(cfg.virtual_animation_seconds, 30);
  max_s := COALESCE(cfg.virtual_max_score, 8);
  per_round := GREATEST(COALESCE(cfg.virtual_matches_per_round, cfg.virtual_concurrent_rounds, 5), 1);

  -- Lock rounds whose betting window expired
  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='scheduled' AND lock_time IS NOT NULL AND lock_time <= now()
  LOOP
    UPDATE matches SET status='live', locked_at=COALESCE(locked_at,now()), updated_at=now() WHERE id=m.id;
    UPDATE markets SET is_open=false WHERE match_id=m.id;
    locked_n := locked_n + 1;
  END LOOP;

  -- Animate score ticks during play window
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

  -- Resolve rounds whose play window expired
  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='live' AND lock_time IS NOT NULL
      AND lock_time + (anim_sec || ' seconds')::interval <= now()
  LOOP
    PERFORM public.auto_resolve_virtual_round(m.id);
    resolved_n := resolved_n + 1;
  END LOOP;

  -- Settle bets touching virtual matches
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

  -- Spawn next batch only when no active rounds remain (full batch at once)
  IF cfg.virtual_cycle_running THEN
    SELECT count(*) INTO active_count FROM matches
      WHERE is_virtual=true AND status IN ('scheduled','live');

    IF active_count = 0 THEN
      batch_id := gen_random_uuid();
      FOR i IN 1..per_round LOOP
        SELECT id INTO t1 FROM teams ORDER BY random() LIMIT 1;
        SELECT id INTO t2 FROM teams WHERE id <> t1 ORDER BY random() LIMIT 1;
        IF t1 IS NULL OR t2 IS NULL THEN EXIT; END IF;
        SELECT name INTO team_a_name FROM teams WHERE id=t1;
        SELECT name INTO team_b_name FROM teams WHERE id=t2;

        INSERT INTO matches(name, home_team_id, away_team_id, start_time, lock_time, status,
                            is_virtual, is_featured, virtual_round_batch_id)
          VALUES (team_a_name || ' vs ' || team_b_name, t1, t2,
                  now() + (dur_sec || ' seconds')::interval,
                  now() + (dur_sec || ' seconds')::interval,
                  'scheduled', true, false, batch_id)
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

        spawned := spawned + 1;
      END LOOP;
    END IF;
  END IF;

  RETURN jsonb_build_object('locked', locked_n, 'resolved', resolved_n, 'spawned', spawned,
                            'swept', swept, 'cycle', cfg.virtual_cycle_running, 'per_round', per_round);
END $function$;