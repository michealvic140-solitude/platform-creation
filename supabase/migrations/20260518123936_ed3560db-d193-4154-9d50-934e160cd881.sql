
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'virtual_tick_10s') THEN
    PERFORM cron.schedule('virtual_tick_10s', '10 seconds', $cron$SELECT public.virtual_tick();$cron$);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.virtual_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  cfg record; m record; anim_sec int; dur_sec int;
  pending_count int;
  t1 uuid; t2 uuid; new_match_id uuid; market_id uuid;
  team_a_name text; team_b_name text;
  locked_n int := 0; resolved_n int := 0; spawned int := 0;
  elapsed numeric; tgt_h int; tgt_a int; max_s int;
BEGIN
  SELECT virtual_cycle_running, virtual_round_duration_seconds, virtual_animation_seconds, virtual_max_score
    INTO cfg FROM app_settings WHERE id=1;
  dur_sec := COALESCE(cfg.virtual_round_duration_seconds, 120);
  anim_sec := COALESCE(cfg.virtual_animation_seconds, 30);
  max_s := COALESCE(cfg.virtual_max_score, 8);

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
      updated_at = now()
    WHERE id = m.id;
  END LOOP;

  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='live' AND lock_time IS NOT NULL AND lock_time + (anim_sec || ' seconds')::interval <= now()
  LOOP
    PERFORM public.auto_resolve_virtual_round(m.id);
    resolved_n := resolved_n + 1;
  END LOOP;

  UPDATE app_settings SET virtual_cycle_last_tick = now() WHERE id=1;

  IF cfg.virtual_cycle_running THEN
    SELECT count(*) INTO pending_count FROM matches
      WHERE is_virtual=true AND status IN ('scheduled','live');
    IF pending_count = 0 THEN
      SELECT id INTO t1 FROM teams ORDER BY random() LIMIT 1;
      SELECT id INTO t2 FROM teams WHERE id <> t1 ORDER BY random() LIMIT 1;
      IF t1 IS NOT NULL AND t2 IS NOT NULL THEN
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

        spawned := 1;
        INSERT INTO audit_logs(actor_id, action, target_type, target_id, metadata)
          VALUES (NULL, 'virtual_round_auto_spawned', 'match', new_match_id::text,
                  jsonb_build_object('teams', jsonb_build_array(team_a_name, team_b_name), 'duration', dur_sec));
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('locked', locked_n, 'resolved', resolved_n, 'spawned', spawned, 'cycle', cfg.virtual_cycle_running);
END $function$;

CREATE OR REPLACE FUNCTION public.auto_resolve_virtual_round(_match_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  m record; mk record; prev record;
  hs int; as_ int; max_s int;
  v_winner_team_id uuid; v_winner_label text;
  v_fb_team_id uuid; v_fb_label text;
  cs_label text; total_kills int;
  cfg record; bonus bigint; xp_per_win int;
  win_rate numeric := 0.0005;
BEGIN
  SELECT * INTO m FROM matches WHERE id = _match_id FOR UPDATE;
  IF m IS NULL OR NOT m.is_virtual THEN RAISE EXCEPTION 'Not a virtual round'; END IF;
  IF m.status = 'ended' THEN RETURN jsonb_build_object('ok', false, 'msg', 'already settled'); END IF;

  SELECT virtual_max_score, virtual_win_bonus_tokens, virtual_xp_per_win, virtual_payout_multiplier
    INTO cfg FROM app_settings WHERE id = 1;
  max_s := COALESCE(cfg.virtual_max_score, 8);
  bonus := COALESCE(cfg.virtual_win_bonus_tokens, 0);
  xp_per_win := COALESCE(cfg.virtual_xp_per_win, 0);

  SELECT home_score, away_score INTO prev FROM matches
    WHERE is_virtual = true AND status = 'ended' AND id <> _match_id
    ORDER BY settled_at DESC NULLS LAST LIMIT 1;

  hs := (abs(hashtext(_match_id::text || ':h')) % (max_s + 1));
  as_ := (abs(hashtext(_match_id::text || ':a')) % (max_s + 1));
  IF prev IS NOT NULL AND hs = prev.home_score AND as_ = prev.away_score THEN
    hs := (hs + 1) % (max_s + 1);
  END IF;
  IF hs = 0 AND as_ = 0 THEN hs := 1; END IF;
  total_kills := hs + as_;
  cs_label := hs || ':' || as_;

  IF hs > as_ THEN v_winner_team_id := m.home_team_id;
  ELSIF as_ > hs THEN v_winner_team_id := m.away_team_id;
  ELSE v_winner_team_id := NULL; END IF;

  IF total_kills = 0 THEN v_fb_team_id := NULL;
  ELSIF random() < (hs::numeric / NULLIF(total_kills,0)) THEN v_fb_team_id := m.home_team_id;
  ELSE v_fb_team_id := m.away_team_id; END IF;

  UPDATE odds o SET is_winner = false FROM markets mm WHERE o.market_id = mm.id AND mm.match_id = _match_id;

  FOR mk IN SELECT * FROM markets WHERE match_id = _match_id LOOP
    IF lower(mk.name) LIKE '%match winner%' OR lower(mk.name) = '1x2' THEN
      IF v_winner_team_id IS NULL THEN v_winner_label := 'Draw';
      ELSIF v_winner_team_id = m.home_team_id THEN SELECT name INTO v_winner_label FROM teams WHERE id = m.home_team_id;
      ELSE SELECT name INTO v_winner_label FROM teams WHERE id = m.away_team_id; END IF;
      UPDATE odds SET is_winner = (label = v_winner_label) WHERE market_id = mk.id;
    ELSIF lower(mk.name) LIKE '%first blood%' THEN
      IF v_fb_team_id IS NOT NULL THEN
        SELECT name INTO v_fb_label FROM teams WHERE id = v_fb_team_id;
        UPDATE odds SET is_winner = (label = v_fb_label) WHERE market_id = mk.id;
      END IF;
    ELSIF lower(mk.name) LIKE '%total kills%' OR lower(mk.name) LIKE '%over/under%' THEN
      UPDATE odds o SET is_winner = CASE
        WHEN lower(o.label) LIKE 'over %' AND total_kills::numeric > NULLIF(regexp_replace(o.label, '[^0-9.]', '', 'g'), '')::numeric THEN true
        WHEN lower(o.label) LIKE 'under %' AND total_kills::numeric < NULLIF(regexp_replace(o.label, '[^0-9.]', '', 'g'), '')::numeric THEN true
        ELSE false END WHERE o.market_id = mk.id;
    ELSIF lower(mk.name) LIKE '%correct score%' THEN
      UPDATE odds SET is_winner = (replace(label,' ','') = cs_label) WHERE market_id = mk.id;
    END IF;
  END LOOP;

  UPDATE matches SET
    status='ended', home_score=hs, away_score=as_,
    winner_team_id=v_winner_team_id, virtual_first_blood_team_id=v_fb_team_id,
    settled_by=NULL, settled_at=now(), updated_at=now()
  WHERE id=_match_id;

  WITH bet_ids AS (SELECT DISTINCT bs.bet_id FROM bet_selections bs WHERE bs.match_id = _match_id),
  bet_status AS (
    SELECT b.id AS bet_id,
      bool_or(o.is_winner IS FALSE AND o.is_winner IS NOT NULL AND m2.status='ended') AS has_loser,
      bool_and(o.is_winner IS TRUE) AS all_winners,
      count(*) FILTER (WHERE m2.status <> 'ended') AS unsettled
    FROM bets b
    JOIN bet_selections bs ON bs.bet_id = b.id
    JOIN odds o ON o.id = bs.odd_id
    JOIN matches m2 ON m2.id = bs.match_id
    WHERE b.id IN (SELECT bet_id FROM bet_ids) AND b.status='open'
    GROUP BY b.id
  )
  UPDATE bets b SET
    status = CASE WHEN bs.has_loser THEN 'lost'::bet_status
                  WHEN bs.all_winners AND bs.unsettled=0 THEN 'won'::bet_status
                  ELSE b.status END,
    settled_at = CASE WHEN bs.has_loser OR (bs.all_winners AND bs.unsettled=0) THEN now() ELSE b.settled_at END
  FROM bet_status bs WHERE b.id = bs.bet_id;

  -- Lucky drop: only ~0.05% of "won" virtual tickets survive
  UPDATE bets b SET status='lost'::bet_status
  WHERE b.id IN (
    SELECT DISTINCT b2.id FROM bets b2
    JOIN bet_selections bs ON bs.bet_id = b2.id
    WHERE bs.match_id = _match_id AND b2.status='won' AND b2.settled_at IS NOT NULL
  ) AND random() > win_rate;

  INSERT INTO virtual_payout_requests(bet_id, user_id, match_id, stake, amount, status)
  SELECT DISTINCT b.id, b.user_id, _match_id, b.stake,
    (b.potential_payout * COALESCE(cfg.virtual_payout_multiplier, 1.0))::bigint + bonus,
    'pending'
  FROM bets b
  JOIN bet_selections bs ON bs.bet_id = b.id
  WHERE bs.match_id = _match_id AND b.status='won' AND b.settled_at IS NOT NULL
  ON CONFLICT (bet_id) DO NOTHING;

  INSERT INTO notifications(user_id, title, body, link)
  SELECT DISTINCT b.user_id, '🏆 Lucky win — awaiting approval',
    'Your virtual ticket ' || b.tracking_id || ' is pending admin approval.',
    '/virtual/history'
  FROM bets b
  JOIN bet_selections bs ON bs.bet_id = b.id
  JOIN virtual_payout_requests vpr ON vpr.bet_id = b.id
  WHERE bs.match_id = _match_id AND vpr.status='pending';

  INSERT INTO audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (NULL, 'virtual_round_auto_resolved', 'match', _match_id::text,
            jsonb_build_object('home', hs, 'away', as_, 'first_blood', v_fb_team_id, 'win_rate', win_rate));

  RETURN jsonb_build_object('ok', true, 'home', hs, 'away', as_, 'first_blood', v_fb_team_id);
END $function$;

GRANT EXECUTE ON FUNCTION public.virtual_tick() TO anon, authenticated;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM matches WHERE is_virtual=true AND status='live' AND lock_time < now() - interval '60 seconds' LOOP
    PERFORM public.auto_resolve_virtual_round(r.id);
  END LOOP;
  PERFORM public.virtual_tick();
END $$;
