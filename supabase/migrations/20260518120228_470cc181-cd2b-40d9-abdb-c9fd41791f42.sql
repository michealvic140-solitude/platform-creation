
-- 1. App settings extensions
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS virtual_cycle_running boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS virtual_round_duration_seconds int NOT NULL DEFAULT 120,
  ADD COLUMN IF NOT EXISTS virtual_animation_seconds int NOT NULL DEFAULT 15,
  ADD COLUMN IF NOT EXISTS virtual_max_score int NOT NULL DEFAULT 8,
  ADD COLUMN IF NOT EXISTS virtual_cycle_last_tick timestamptz;

-- 2. Pending payouts table
CREATE TABLE IF NOT EXISTS public.virtual_payout_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bet_id uuid NOT NULL,
  user_id uuid NOT NULL,
  match_id uuid NOT NULL,
  stake bigint NOT NULL,
  amount bigint NOT NULL,
  status text NOT NULL DEFAULT 'pending', -- pending|approved|declined|claimed
  decline_reason text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  claimed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(bet_id)
);
CREATE INDEX IF NOT EXISTS idx_vpr_status ON public.virtual_payout_requests(status);
CREATE INDEX IF NOT EXISTS idx_vpr_user ON public.virtual_payout_requests(user_id);

ALTER TABLE public.virtual_payout_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "vpr own select" ON public.virtual_payout_requests;
CREATE POLICY "vpr own select" ON public.virtual_payout_requests FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin(auth.uid()));

DROP POLICY IF EXISTS "vpr admin all" ON public.virtual_payout_requests;
CREATE POLICY "vpr admin all" ON public.virtual_payout_requests FOR ALL TO authenticated
  USING (is_admin(auth.uid())) WITH CHECK (is_admin(auth.uid()));

-- 3. Toggle cycle
CREATE OR REPLACE FUNCTION public.admin_set_virtual_cycle(_running boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  UPDATE app_settings SET virtual_cycle_running = _running, updated_at = now() WHERE id = 1;
  INSERT INTO audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (auth.uid(), CASE WHEN _running THEN 'virtual_cycle_started' ELSE 'virtual_cycle_paused' END, 'cycle', '1', jsonb_build_object('at', now()));
  RETURN jsonb_build_object('ok', true, 'running', _running);
END $$;

-- 4. Auto-resolve with varied random scores
CREATE OR REPLACE FUNCTION public.auto_resolve_virtual_round(_match_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m record; mk record; prev record;
  hs int; as_ int; max_s int; tries int := 0;
  winner_team_id uuid; winner_label text;
  fb_team_id uuid; fb_label text;
  cs_label text; total_kills int;
  cfg record; bonus bigint; xp_per_win int;
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

  LOOP
    hs := floor(random() * (max_s + 1))::int;
    as_ := floor(random() * (max_s + 1))::int;
    tries := tries + 1;
    EXIT WHEN tries >= 6 OR prev IS NULL OR NOT (hs = prev.home_score AND as_ = prev.away_score);
  END LOOP;
  IF hs = 0 AND as_ = 0 THEN
    IF random() < 0.7 THEN hs := 1 + floor(random()*max_s)::int; END IF;
  END IF;
  total_kills := hs + as_;
  cs_label := hs || ':' || as_;

  IF hs > as_ THEN winner_team_id := m.home_team_id;
  ELSIF as_ > hs THEN winner_team_id := m.away_team_id;
  ELSE winner_team_id := NULL; END IF;

  IF total_kills = 0 THEN fb_team_id := NULL;
  ELSIF random() < (hs::numeric / NULLIF(total_kills,0)) THEN fb_team_id := m.home_team_id;
  ELSE fb_team_id := m.away_team_id; END IF;

  UPDATE odds o SET is_winner = false FROM markets mm WHERE o.market_id = mm.id AND mm.match_id = _match_id;

  FOR mk IN SELECT * FROM markets WHERE match_id = _match_id LOOP
    IF lower(mk.name) LIKE '%match winner%' OR lower(mk.name) = '1x2' THEN
      IF winner_team_id IS NULL THEN winner_label := 'Draw';
      ELSIF winner_team_id = m.home_team_id THEN SELECT name INTO winner_label FROM teams WHERE id = m.home_team_id;
      ELSE SELECT name INTO winner_label FROM teams WHERE id = m.away_team_id; END IF;
      UPDATE odds SET is_winner = (label = winner_label) WHERE market_id = mk.id;
    ELSIF lower(mk.name) LIKE '%first blood%' THEN
      IF fb_team_id IS NOT NULL THEN
        SELECT name INTO fb_label FROM teams WHERE id = fb_team_id;
        UPDATE odds SET is_winner = (label = fb_label) WHERE market_id = mk.id;
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
    winner_team_id=winner_team_id, virtual_first_blood_team_id=fb_team_id,
    settled_by=NULL, settled_at=now(), updated_at=now()
  WHERE id=_match_id;

  -- Settle bets touching this match (mark won/lost) but DON'T credit yet
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

  -- Create pending payout requests for winners (no credit yet)
  INSERT INTO virtual_payout_requests(bet_id, user_id, match_id, stake, amount, status)
  SELECT DISTINCT b.id, b.user_id, _match_id, b.stake,
    (b.potential_payout * COALESCE(cfg.virtual_payout_multiplier, 1.0))::bigint + bonus,
    'pending'
  FROM bets b
  JOIN bet_selections bs ON bs.bet_id = b.id
  WHERE bs.match_id = _match_id AND b.status='won' AND b.settled_at IS NOT NULL
  ON CONFLICT (bet_id) DO NOTHING;

  -- Notify winners they have a pending claim
  INSERT INTO notifications(user_id, title, body, link)
  SELECT DISTINCT b.user_id, '🏆 Bet won — awaiting approval',
    'Your virtual ticket ' || b.tracking_id || ' is pending admin approval.',
    '/virtual/history'
  FROM bets b
  JOIN bet_selections bs ON bs.bet_id = b.id
  JOIN virtual_payout_requests vpr ON vpr.bet_id = b.id
  WHERE bs.match_id = _match_id AND vpr.status='pending';

  INSERT INTO audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (NULL, 'virtual_round_auto_resolved', 'match', _match_id::text,
            jsonb_build_object('home', hs, 'away', as_, 'first_blood', fb_team_id));

  RETURN jsonb_build_object('ok', true, 'home', hs, 'away', as_, 'first_blood', fb_team_id);
END $$;

-- 5. Admin review payout
CREATE OR REPLACE FUNCTION public.admin_review_virtual_payout(_id uuid, _approve boolean, _reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; new_bal bigint;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO r FROM virtual_payout_requests WHERE id = _id FOR UPDATE;
  IF r IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  IF r.status <> 'pending' THEN RAISE EXCEPTION 'Already reviewed (%)', r.status; END IF;

  IF _approve THEN
    UPDATE virtual_payout_requests SET status='approved', reviewed_by=auth.uid(), reviewed_at=now() WHERE id=_id;
    INSERT INTO notifications(user_id,title,body,link)
      VALUES (r.user_id, '✅ Payout approved', 'Claim ' || r.amount || ' tokens now.', '/virtual/history');
  ELSE
    UPDATE virtual_payout_requests SET status='declined', decline_reason=_reason, reviewed_by=auth.uid(), reviewed_at=now() WHERE id=_id;
    -- Refund stake
    UPDATE profiles SET token_balance = token_balance + r.stake WHERE id = r.user_id RETURNING token_balance INTO new_bal;
    INSERT INTO token_transactions(user_id, amount, balance_after, kind, description)
      VALUES (r.user_id, r.stake, new_bal, 'bet_refund', 'Virtual payout declined: ' || COALESCE(_reason,''));
    UPDATE bets SET status='refunded' WHERE id = r.bet_id;
    INSERT INTO notifications(user_id,title,body,link)
      VALUES (r.user_id, '❌ Payout declined', COALESCE(_reason,'Stake refunded.'), '/virtual/history');
  END IF;
  INSERT INTO audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (auth.uid(), CASE WHEN _approve THEN 'virtual_payout_approved' ELSE 'virtual_payout_declined' END,
            'payout', _id::text, jsonb_build_object('amount', r.amount, 'reason', _reason));
  RETURN jsonb_build_object('ok', true);
END $$;

-- 6. User claim approved payout
CREATE OR REPLACE FUNCTION public.claim_virtual_payout(_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; new_bal bigint;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO r FROM virtual_payout_requests WHERE id = _id FOR UPDATE;
  IF r IS NULL OR r.user_id <> auth.uid() THEN RAISE EXCEPTION 'Not yours'; END IF;
  IF r.status <> 'approved' THEN RAISE EXCEPTION 'Not approved'; END IF;
  UPDATE profiles SET token_balance = token_balance + r.amount, xp = xp + COALESCE((SELECT virtual_xp_per_win FROM app_settings WHERE id=1),0)
    WHERE id = auth.uid() RETURNING token_balance INTO new_bal;
  INSERT INTO token_transactions(user_id, amount, balance_after, kind, description)
    VALUES (auth.uid(), r.amount, new_bal, 'bet_win', 'Virtual claim');
  UPDATE virtual_payout_requests SET status='claimed', claimed_at=now() WHERE id=_id;
  RETURN jsonb_build_object('ok', true, 'amount', r.amount, 'balance', new_bal);
END $$;

-- 7. Multi-leg ticket place
CREATE OR REPLACE FUNCTION public.place_virtual_ticket(_selections jsonb, _stake bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid uuid := auth.uid(); p record; cfg record;
  total_odds numeric := 1; payout bigint; bet_id uuid; tracking text; new_bal bigint;
  s jsonb; o record; mk record; m record;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF jsonb_array_length(_selections) < 1 THEN RAISE EXCEPTION 'No selections'; END IF;
  SELECT * INTO p FROM profiles WHERE id = uid FOR UPDATE;
  IF p.is_banned OR p.is_restricted THEN RAISE EXCEPTION 'Account restricted'; END IF;
  SELECT virtual_min_stake, virtual_max_stake, max_payout INTO cfg FROM app_settings WHERE id=1;
  IF _stake < COALESCE(cfg.virtual_min_stake,100000) THEN RAISE EXCEPTION 'Stake below minimum'; END IF;
  IF _stake > COALESCE(cfg.virtual_max_stake,10000000) THEN RAISE EXCEPTION 'Stake above maximum'; END IF;
  IF p.token_balance < _stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  -- Validate
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

  UPDATE profiles SET token_balance = token_balance - _stake WHERE id = uid RETURNING token_balance INTO new_bal;
  INSERT INTO notifications(user_id, title, body, link)
    VALUES (uid, 'Virtual ticket placed', tracking || ' · ' || _stake || ' tokens', '/ticket/' || bet_id);
  RETURN jsonb_build_object('bet_id', bet_id, 'tracking_id', tracking, 'stake', _stake, 'payout', payout, 'balance', new_bal, 'total_odds', total_odds);
END $$;

-- 8. Tick engine (callable by anyone — internal logic is safe)
CREATE OR REPLACE FUNCTION public.virtual_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  cfg record; m record; anim_sec int; dur_sec int;
  pending_count int; live_count int;
  t1 uuid; t2 uuid; new_match_id uuid; market_id uuid;
  team_a_name text; team_b_name text;
  locked_n int := 0; resolved_n int := 0; spawned int := 0;
BEGIN
  SELECT virtual_cycle_running, virtual_round_duration_seconds, virtual_animation_seconds
    INTO cfg FROM app_settings WHERE id=1;
  dur_sec := COALESCE(cfg.virtual_round_duration_seconds, 120);
  anim_sec := COALESCE(cfg.virtual_animation_seconds, 15);

  -- Lock rounds whose lock_time has passed
  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='scheduled' AND lock_time IS NOT NULL AND lock_time <= now()
  LOOP
    UPDATE matches SET status='live', locked_at=COALESCE(locked_at,now()), updated_at=now() WHERE id=m.id;
    UPDATE markets SET is_open=false WHERE match_id=m.id;
    locked_n := locked_n + 1;
  END LOOP;

  -- Resolve rounds whose animation has finished
  FOR m IN SELECT id FROM matches
    WHERE is_virtual=true AND status='live' AND lock_time IS NOT NULL AND lock_time + (anim_sec || ' seconds')::interval <= now()
  LOOP
    PERFORM public.auto_resolve_virtual_round(m.id);
    resolved_n := resolved_n + 1;
  END LOOP;

  UPDATE app_settings SET virtual_cycle_last_tick = now() WHERE id=1;

  -- Spawn next round if cycle running and there's nothing live/scheduled
  IF cfg.virtual_cycle_running THEN
    SELECT count(*) INTO pending_count FROM matches
      WHERE is_virtual=true AND status IN ('scheduled','live');
    IF pending_count = 0 THEN
      -- Pick two distinct teams
      SELECT id INTO t1 FROM teams ORDER BY random() LIMIT 1;
      SELECT id INTO t2 FROM teams WHERE id <> t1 ORDER BY random() LIMIT 1;
      IF t1 IS NOT NULL AND t2 IS NOT NULL THEN
        SELECT name INTO team_a_name FROM teams WHERE id=t1;
        SELECT name INTO team_b_name FROM teams WHERE id=t2;
        INSERT INTO matches(name, home_team_id, away_team_id, start_time, lock_time, status, is_virtual, is_featured)
          VALUES (team_a_name || ' vs ' || team_b_name, t1, t2, now(), now() + (dur_sec || ' seconds')::interval, 'scheduled', true, false)
          RETURNING id INTO new_match_id;

        -- Match Winner
        INSERT INTO markets(match_id, name, is_open) VALUES (new_match_id, 'Match Winner', true) RETURNING id INTO market_id;
        INSERT INTO odds(market_id, label, value) VALUES
          (market_id, team_a_name, round((1.6 + random()*1.4)::numeric,2)),
          (market_id, 'Draw', round((3.0 + random()*1.5)::numeric,2)),
          (market_id, team_b_name, round((1.6 + random()*1.4)::numeric,2));

        -- First Blood
        INSERT INTO markets(match_id, name, is_open) VALUES (new_match_id, 'First Blood', true) RETURNING id INTO market_id;
        INSERT INTO odds(market_id, label, value) VALUES
          (market_id, team_a_name, round((1.7 + random()*0.4)::numeric,2)),
          (market_id, team_b_name, round((1.7 + random()*0.4)::numeric,2));

        -- Total Kills O/U 4.5
        INSERT INTO markets(match_id, name, is_open) VALUES (new_match_id, 'Total Kills', true) RETURNING id INTO market_id;
        INSERT INTO odds(market_id, label, value) VALUES
          (market_id, 'Over 4.5', round((1.8 + random()*0.4)::numeric,2)),
          (market_id, 'Under 4.5', round((1.8 + random()*0.4)::numeric,2));

        -- Correct Score grid
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
END $$;

GRANT EXECUTE ON FUNCTION public.virtual_tick() TO anon, authenticated;
