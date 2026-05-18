CREATE OR REPLACE FUNCTION public.refresh_virtual_selection_results(_match_id uuid DEFAULT NULL::uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE updated_count integer := 0;
BEGIN
  WITH upd AS (
    UPDATE bet_selections bs
    SET result = CASE
      WHEN o.is_winner IS TRUE THEN 'won'
      WHEN o.is_winner IS FALSE THEN 'lost'
      ELSE bs.result
    END
    FROM odds o
    JOIN markets mk ON mk.id = o.market_id
    JOIN matches m ON m.id = mk.match_id
    WHERE bs.odd_id = o.id
      AND bs.match_id = m.id
      AND m.is_virtual = true
      AND m.status = 'ended'
      AND o.is_winner IS NOT NULL
      AND (_match_id IS NULL OR m.id = _match_id)
      AND (bs.result IS DISTINCT FROM CASE WHEN o.is_winner IS TRUE THEN 'won' ELSE 'lost' END)
    RETURNING bs.id
  )
  SELECT count(*) INTO updated_count FROM upd;

  RETURN updated_count;
END $$;

CREATE OR REPLACE FUNCTION public.auto_resolve_virtual_round(_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  m record; mk record; prev record;
  hs int; as_ int; max_s int;
  v_winner_team_id uuid; v_winner_label text;
  v_fb_team_id uuid; v_fb_label text;
  cs_label text; total_kills int;
  cfg record; bonus bigint; xp_per_win int;
  win_rate numeric := 0.0005;
  selection_results int := 0;
BEGIN
  SELECT * INTO m FROM matches WHERE id = _match_id FOR UPDATE;
  IF m IS NULL OR NOT m.is_virtual THEN RAISE EXCEPTION 'Not a virtual round'; END IF;
  IF m.status = 'ended' THEN
    selection_results := public.refresh_virtual_selection_results(_match_id);
    RETURN jsonb_build_object('ok', false, 'msg', 'already settled', 'selection_results', selection_results);
  END IF;

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

  selection_results := public.refresh_virtual_selection_results(_match_id);

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
            jsonb_build_object('home', hs, 'away', as_, 'first_blood', v_fb_team_id, 'win_rate', win_rate, 'selection_results', selection_results));

  RETURN jsonb_build_object('ok', true, 'home', hs, 'away', as_, 'first_blood', v_fb_team_id, 'selection_results', selection_results);
END $$;

CREATE OR REPLACE FUNCTION public.resolve_virtual_round(_match_id uuid, _home_score integer, _away_score integer, _first_blood_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  m record; mk record;
  total_kills int := _home_score + _away_score;
  winner_team_id uuid;
  winner_label text;
  cs_label text;
  cfg record;
  bonus bigint;
  xp_per_win int;
  selection_results int := 0;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO m FROM matches WHERE id = _match_id FOR UPDATE;
  IF m IS NULL THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF NOT m.is_virtual THEN RAISE EXCEPTION 'Not a virtual round'; END IF;
  IF m.status = 'ended' THEN RAISE EXCEPTION 'Already settled'; END IF;

  SELECT virtual_payout_multiplier, virtual_win_bonus_tokens, virtual_xp_per_win INTO cfg FROM app_settings WHERE id=1;
  bonus := COALESCE(cfg.virtual_win_bonus_tokens, 0);
  xp_per_win := COALESCE(cfg.virtual_xp_per_win, 0);

  IF _home_score > _away_score THEN winner_team_id := m.home_team_id;
  ELSIF _away_score > _home_score THEN winner_team_id := m.away_team_id;
  ELSE winner_team_id := NULL; END IF;

  cs_label := _home_score || ':' || _away_score;

  UPDATE odds o SET is_winner = false
    FROM markets mm WHERE o.market_id = mm.id AND mm.match_id = _match_id;

  FOR mk IN SELECT * FROM markets WHERE match_id = _match_id LOOP
    IF lower(mk.name) LIKE '%match winner%' OR lower(mk.name) = '1x2' THEN
      IF winner_team_id IS NULL THEN winner_label := 'Draw';
      ELSIF winner_team_id = m.home_team_id THEN SELECT name INTO winner_label FROM teams WHERE id = m.home_team_id;
      ELSE SELECT name INTO winner_label FROM teams WHERE id = m.away_team_id; END IF;
      UPDATE odds SET is_winner = (label = winner_label) WHERE market_id = mk.id;
    ELSIF lower(mk.name) LIKE '%first blood%' THEN
      IF _first_blood_team_id IS NOT NULL THEN
        SELECT name INTO winner_label FROM teams WHERE id = _first_blood_team_id;
        UPDATE odds SET is_winner = (label = winner_label) WHERE market_id = mk.id;
      END IF;
    ELSIF lower(mk.name) LIKE '%total kills%' OR lower(mk.name) LIKE '%over/under%' THEN
      UPDATE odds o SET is_winner = CASE
        WHEN lower(o.label) LIKE 'over %' AND total_kills::numeric > NULLIF(regexp_replace(o.label, '[^0-9.]', '', 'g'), '')::numeric THEN true
        WHEN lower(o.label) LIKE 'under %' AND total_kills::numeric < NULLIF(regexp_replace(o.label, '[^0-9.]', '', 'g'), '')::numeric THEN true
        ELSE false END
      WHERE o.market_id = mk.id;
    ELSIF lower(mk.name) LIKE '%correct score%' THEN
      UPDATE odds SET is_winner = (replace(label, ' ', '') = cs_label) WHERE market_id = mk.id;
    END IF;
  END LOOP;

  UPDATE matches SET
    status = 'ended', home_score = _home_score, away_score = _away_score,
    winner_team_id = winner_team_id, virtual_first_blood_team_id = _first_blood_team_id,
    settled_by = auth.uid(), settled_at = now(), updated_at = now()
  WHERE id = _match_id;

  selection_results := public.refresh_virtual_selection_results(_match_id);

  WITH bet_ids AS (SELECT DISTINCT bs.bet_id FROM bet_selections bs WHERE bs.match_id = _match_id),
  bet_status AS (
    SELECT b.id AS bet_id,
      bool_or(o.is_winner IS FALSE AND o.is_winner IS NOT NULL AND m2.status = 'ended') AS has_loser,
      bool_and(o.is_winner IS TRUE) AS all_winners,
      count(*) FILTER (WHERE m2.status <> 'ended') AS unsettled
    FROM bets b
    JOIN bet_selections bs ON bs.bet_id = b.id
    JOIN odds o ON o.id = bs.odd_id
    JOIN matches m2 ON m2.id = bs.match_id
    WHERE b.id IN (SELECT bet_id FROM bet_ids) AND b.status = 'open'
    GROUP BY b.id
  )
  UPDATE bets b SET
    status = CASE WHEN bs.has_loser THEN 'lost'::bet_status
                  WHEN bs.all_winners AND bs.unsettled = 0 THEN 'won'::bet_status
                  ELSE b.status END,
    settled_at = CASE WHEN bs.has_loser OR (bs.all_winners AND bs.unsettled = 0) THEN now() ELSE b.settled_at END
  FROM bet_status bs WHERE b.id = bs.bet_id;

  WITH won_bets AS (
    SELECT b.id, b.user_id, b.potential_payout, b.tracking_id FROM bets b
    JOIN bet_selections bs ON bs.bet_id = b.id
    WHERE bs.match_id = _match_id AND b.status = 'won' AND b.settled_at IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM token_transactions tt WHERE tt.user_id = b.user_id AND tt.kind = 'bet_win' AND tt.description = 'Win: ' || b.tracking_id)
  )
  UPDATE profiles p
  SET token_balance = p.token_balance + (wb.potential_payout * COALESCE(cfg.virtual_payout_multiplier,1.0))::bigint + bonus,
      xp = p.xp + xp_per_win
  FROM won_bets wb WHERE p.id = wb.user_id;

  INSERT INTO token_transactions(user_id, amount, balance_after, kind, description)
  SELECT b.user_id,
    (b.potential_payout * COALESCE(cfg.virtual_payout_multiplier,1.0))::bigint + bonus,
    (SELECT token_balance FROM profiles WHERE id = b.user_id),
    'bet_win', 'Win: ' || b.tracking_id
  FROM bets b
  JOIN bet_selections bs ON bs.bet_id = b.id
  WHERE bs.match_id = _match_id AND b.status = 'won' AND b.settled_at IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM token_transactions tt WHERE tt.user_id = b.user_id AND tt.kind = 'bet_win' AND tt.description = 'Win: ' || b.tracking_id);

  INSERT INTO audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (auth.uid(), 'virtual_round_resolved', 'match', _match_id::text,
            jsonb_build_object('home', _home_score, 'away', _away_score, 'first_blood', _first_blood_team_id, 'multiplier', cfg.virtual_payout_multiplier, 'bonus', bonus, 'selection_results', selection_results));

  RETURN jsonb_build_object('ok', true, 'winner_team_id', winner_team_id, 'total_kills', total_kills, 'selection_results', selection_results);
END $$;

SELECT public.refresh_virtual_selection_results(NULL);

GRANT EXECUTE ON FUNCTION public.refresh_virtual_selection_results(uuid) TO authenticated;