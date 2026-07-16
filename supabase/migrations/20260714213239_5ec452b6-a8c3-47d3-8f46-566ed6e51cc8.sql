
-- 1) Allow teams to belong to both pools (generic + football) via sport='both'
ALTER TABLE public.teams DROP CONSTRAINT IF EXISTS teams_sport_check;
ALTER TABLE public.teams ADD CONSTRAINT teams_sport_check
  CHECK (sport IN ('generic','football','both'));

-- 2) Championship start: match teams whose sport = v_sport OR 'both'
CREATE OR REPLACE FUNCTION public.championship_start(p_tournament uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_teams UUID[]; v_gap INT; v_live INT; v_book INT; i INT;
  v_kind TEXT; v_sport TEXT;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can start championships';
  END IF;

  SELECT kind, COALESCE(stage_gap_seconds, 20) INTO v_kind, v_gap
    FROM public.tournaments WHERE id = p_tournament;
  v_sport := CASE WHEN v_kind = 'championship_football' THEN 'football' ELSE 'generic' END;

  SELECT
    COALESCE(championship_booking_seconds, 120),
    COALESCE(championship_stage_live_seconds, 30)
    INTO v_book, v_live
    FROM public.app_settings WHERE id = 1;

  SELECT ARRAY(
    SELECT id FROM public.teams
    WHERE COALESCE(sport, 'generic') IN (v_sport, 'both')
    ORDER BY random() LIMIT 16
  ) INTO v_teams;

  IF array_length(v_teams, 1) IS NULL OR array_length(v_teams, 1) < 16 THEN
    RAISE EXCEPTION 'Need at least 16 % teams (found %). Tag more teams as % in Clans admin.',
      v_sport, COALESCE(array_length(v_teams, 1), 0), v_sport;
  END IF;

  DELETE FROM public.tournament_matches WHERE tournament_id = p_tournament;
  FOR i IN 0..7 LOOP
    INSERT INTO public.tournament_matches (tournament_id, round, round_name, slot, participant_a_id, participant_b_id, status, score_a, score_b)
    VALUES (p_tournament, 1, 'R16', i, v_teams[i*2+1], v_teams[i*2+2], 'pending', 0, 0);
  END LOOP;

  UPDATE public.tournaments
     SET status = 'booking',
         current_stage = 'R16',
         team_ids = v_teams,
         booking_closes_at = now() + (v_book || ' seconds')::interval,
         stage_live_seconds = v_live,
         next_stage_at = NULL,
         stage_live_ends_at = NULL,
         starts_at = COALESCE(starts_at, now()),
         updated_at = now()
   WHERE id = p_tournament;

  RETURN jsonb_build_object('ok', true, 'tournament_id', p_tournament, 'sport', v_sport, 'booking_seconds', v_book);
END; $$;

-- 3) Auto-restart bootstrap: same tolerance
CREATE OR REPLACE FUNCTION public.championship_bootstrap_if_needed()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s RECORD; v_new_tid UUID; v_count INT := 0; v_teams INT;
BEGIN
  SELECT virtual_championship_enabled,
         virtual_championship_football_enabled,
         virtual_championship_auto_restart,
         COALESCE(championship_stage_gap_seconds, 20) AS gap
    INTO s FROM public.app_settings WHERE id = 1;

  IF NOT COALESCE(s.virtual_championship_auto_restart, false) THEN
    RETURN 0;
  END IF;

  IF COALESCE(s.virtual_championship_enabled, false) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.tournaments
       WHERE kind = 'championship_virtual'
         AND status IN ('scheduled','booking','live')
    ) THEN
      SELECT COUNT(*) INTO v_teams FROM public.teams
        WHERE COALESCE(sport,'generic') IN ('generic','both');
      IF v_teams >= 16 THEN
        INSERT INTO public.tournaments (name, kind, status, starts_at, stage_gap_seconds, bracket_size, current_stage)
        VALUES ('Auto Championship ' || to_char(now(), 'Mon DD HH24:MI'),
                'championship_virtual', 'scheduled', now() + interval '20 seconds', s.gap, 16, 'R16')
        RETURNING id INTO v_new_tid;
        PERFORM public.championship_autostart(v_new_tid);
        v_count := v_count + 1;
      END IF;
    END IF;
  END IF;

  IF COALESCE(s.virtual_championship_football_enabled, false) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.tournaments
       WHERE kind = 'championship_football'
         AND status IN ('scheduled','booking','live')
    ) THEN
      SELECT COUNT(*) INTO v_teams FROM public.teams
        WHERE COALESCE(sport,'generic') IN ('football','both');
      IF v_teams >= 16 THEN
        INSERT INTO public.tournaments (name, kind, status, starts_at, stage_gap_seconds, bracket_size, current_stage)
        VALUES ('Auto Football Cup ' || to_char(now(), 'Mon DD HH24:MI'),
                'championship_football', 'scheduled', now() + interval '20 seconds', s.gap, 16, 'R16')
        RETURNING id INTO v_new_tid;
        PERFORM public.championship_autostart(v_new_tid);
        v_count := v_count + 1;
      END IF;
    END IF;
  END IF;

  RETURN v_count;
END; $$;

-- 4) Push notification on losing virtual bets, so users get "Bet lost" pushes too.
CREATE OR REPLACE FUNCTION public.resolve_virtual_round(_match_id uuid, _home_score integer DEFAULT NULL, _away_score integer DEFAULT NULL, _first_blood_team_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m public.matches%ROWTYPE;
  planned record;
  cfg record;
  hs integer;
  as_ integer;
  fb uuid;
  winner uuid;
  bet record;
  unresolved_count integer;
  has_lost boolean;
  is_virtual_bet boolean;
  payout_amount bigint;
  prev_status text;
BEGIN
  SELECT * INTO m FROM public.matches WHERE id = _match_id AND is_virtual = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  SELECT * INTO planned FROM public.virtual_score_for_match(_match_id);
  SELECT virtual_payout_multiplier, virtual_win_bonus_tokens INTO cfg FROM public.app_settings WHERE id = 1;

  hs := GREATEST(0, COALESCE(_home_score, CASE WHEN m.status = 'ended' THEN m.home_score END, planned.home_score, 0));
  as_ := GREATEST(0, COALESCE(_away_score, CASE WHEN m.status = 'ended' THEN m.away_score END, planned.away_score, 0));
  fb := COALESCE(_first_blood_team_id, CASE WHEN m.status = 'ended' THEN m.virtual_first_blood_team_id END, planned.first_blood_team_id,
                 CASE WHEN hs >= as_ THEN m.home_team_id ELSE m.away_team_id END);
  winner := CASE WHEN hs > as_ THEN m.home_team_id WHEN as_ > hs THEN m.away_team_id ELSE NULL END;

  UPDATE public.markets SET is_open = false WHERE match_id = _match_id;
  UPDATE public.odds o SET is_winner = false FROM public.markets mk WHERE o.market_id = mk.id AND mk.match_id = _match_id;

  UPDATE public.odds o SET is_winner = CASE
    WHEN winner IS NULL AND lower(o.label) = 'draw' THEN true
    WHEN winner = m.home_team_id AND lower(o.label) = lower(COALESCE((SELECT name FROM public.teams WHERE id = m.home_team_id), '')) THEN true
    WHEN winner = m.away_team_id AND lower(o.label) = lower(COALESCE((SELECT name FROM public.teams WHERE id = m.away_team_id), '')) THEN true
    ELSE false END
    FROM public.markets mk WHERE o.market_id = mk.id AND mk.match_id = _match_id AND (mk.name ILIKE '%winner%' OR mk.name ILIKE '%win / draw / lose%' OR lower(mk.name) = '1x2');

  UPDATE public.odds o SET is_winner = (
    (fb = m.home_team_id AND lower(o.label) = lower(COALESCE((SELECT name FROM public.teams WHERE id = m.home_team_id), '')))
    OR (fb = m.away_team_id AND lower(o.label) = lower(COALESCE((SELECT name FROM public.teams WHERE id = m.away_team_id), '')))
  ) FROM public.markets mk WHERE o.market_id = mk.id AND mk.match_id = _match_id AND mk.name ILIKE '%first%blood%';

  UPDATE public.odds o SET is_winner = (replace(o.label, '-', ':') = hs || ':' || as_)
    FROM public.markets mk WHERE o.market_id = mk.id AND mk.match_id = _match_id AND mk.name ILIKE '%correct%score%';

  UPDATE public.odds o SET is_winner = CASE
    WHEN o.label ILIKE 'Over%' THEN (hs + as_) > COALESCE(NULLIF(regexp_replace(o.label, '[^0-9.]', '', 'g'), '')::numeric, 4.5)
    WHEN o.label ILIKE 'Under%' THEN (hs + as_) < COALESCE(NULLIF(regexp_replace(o.label, '[^0-9.]', '', 'g'), '')::numeric, 4.5)
    ELSE false END
    FROM public.markets mk WHERE o.market_id = mk.id AND mk.match_id = _match_id AND mk.name ILIKE '%total%';

  UPDATE public.matches SET status = 'ended', home_score = hs, away_score = as_,
    winner_team_id = winner, virtual_first_blood_team_id = fb,
    settled_at = COALESCE(settled_at, now()), updated_at = now()
   WHERE id = _match_id;

  FOR bet IN SELECT DISTINCT b.* FROM public.bets b
    JOIN public.bet_selections bs ON bs.bet_id = b.id
    WHERE bs.match_id = _match_id AND b.status IN ('open', 'won')
  LOOP
    prev_status := bet.status;
    UPDATE public.bet_selections bs
      SET result = CASE WHEN o.is_winner IS TRUE THEN 'won' ELSE 'lost' END
      FROM public.odds o
      WHERE bs.odd_id = o.id AND bs.bet_id = bet.id AND bs.match_id = _match_id;

    SELECT COUNT(*) FILTER (WHERE bs2.result IS NULL),
           COALESCE(bool_or(bs2.result = 'lost'), false)
      INTO unresolved_count, has_lost
      FROM public.bet_selections bs2 WHERE bs2.bet_id = bet.id;

    SELECT COALESCE(bool_or(mt.is_virtual), false) INTO is_virtual_bet
      FROM public.bet_selections bs3
      JOIN public.matches mt ON mt.id = bs3.match_id
     WHERE bs3.bet_id = bet.id;

    IF has_lost IS TRUE THEN
      UPDATE public.bets SET status = 'lost', settled_at = COALESCE(settled_at, now()) WHERE id = bet.id;
      IF prev_status <> 'lost' THEN
        INSERT INTO public.notifications (user_id, title, body, link)
          VALUES (bet.user_id, 'Bet lost',
                  'Your ticket ' || bet.tracking_id || ' did not win this round.',
                  '/ticket/' || bet.id::text);
      END IF;
    ELSIF unresolved_count = 0 THEN
      UPDATE public.bets SET status = 'won', settled_at = COALESCE(settled_at, now()) WHERE id = bet.id;
      IF prev_status <> 'won' THEN
        IF is_virtual_bet IS TRUE THEN
          payout_amount := (bet.potential_payout * COALESCE(cfg.virtual_payout_multiplier, 1.0))::bigint + COALESCE(cfg.virtual_win_bonus_tokens, 0);
          INSERT INTO public.virtual_payout_requests(bet_id, user_id, match_id, stake, amount, status)
            VALUES (bet.id, bet.user_id, _match_id, bet.stake, payout_amount, 'pending')
            ON CONFLICT (bet_id) DO NOTHING;
          INSERT INTO public.notifications (user_id, title, body, link)
            VALUES (bet.user_id, 'Virtual ticket won — claim now',
              bet.tracking_id || ' is eligible for a ' || payout_amount::text || ' token payout.',
              '/virtual/history');
        ELSE
          UPDATE public.profiles SET token_balance = token_balance + bet.potential_payout WHERE id = bet.user_id;
          INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
            SELECT bet.user_id, bet.potential_payout, token_balance, 'bet_won', 'Win ' || bet.tracking_id
              FROM public.profiles WHERE id = bet.user_id;
          INSERT INTO public.notifications (user_id, title, body, link)
            VALUES (bet.user_id, 'Ticket won', bet.tracking_id || ' paid ' || bet.potential_payout::text || ' tokens.', '/ticket/' || bet.id::text);
        END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'home', hs, 'away', as_, 'first_blood', fb);
END; $$;
