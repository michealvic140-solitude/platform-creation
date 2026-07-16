
-- 1. app_settings: booking + live duration knobs
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS championship_booking_seconds int NOT NULL DEFAULT 120,
  ADD COLUMN IF NOT EXISTS championship_stage_live_seconds int NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS championship_stage_gap_seconds int NOT NULL DEFAULT 20;

-- 2. tournaments: booking + live-stage columns
ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS booking_closes_at timestamptz,
  ADD COLUMN IF NOT EXISTS stage_live_seconds int NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS stage_live_ends_at timestamptz;

-- 3. tournament_matches: live commentary log
ALTER TABLE public.tournament_matches
  ADD COLUMN IF NOT EXISTS live_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS live_events jsonb NOT NULL DEFAULT '[]'::jsonb;

-- 4. Drop duplicate championship bets and add one-per-tournament unique index
DELETE FROM public.championship_bets a
  USING public.championship_bets b
 WHERE a.user_id = b.user_id
   AND a.tournament_id = b.tournament_id
   AND a.created_at > b.created_at;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_champ_bet_user_tournament
  ON public.championship_bets(user_id, tournament_id);

-- 5. place_championship_bet: enforce booking-phase only + one bet per tournament
CREATE OR REPLACE FUNCTION public.place_championship_bet(
  p_tournament uuid, p_kind text, p_team uuid, p_stage text, p_match uuid, p_stake bigint, p_odds numeric
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_user UUID := auth.uid(); v_bal BIGINT; v_id UUID; v_status TEXT; v_existing UUID;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_stake <= 0 THEN RAISE EXCEPTION 'Invalid stake'; END IF;

  SELECT status INTO v_status FROM public.tournaments WHERE id = p_tournament;
  IF v_status <> 'booking' THEN
    RAISE EXCEPTION 'Booking is closed for this championship';
  END IF;

  SELECT id INTO v_existing FROM public.championship_bets
   WHERE user_id = v_user AND tournament_id = p_tournament LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'You already booked a bet for this championship';
  END IF;

  SELECT token_balance INTO v_bal FROM public.profiles WHERE id = v_user FOR UPDATE;
  IF v_bal IS NULL OR v_bal < p_stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  UPDATE public.profiles SET token_balance = token_balance - p_stake WHERE id = v_user;

  INSERT INTO public.championship_bets (user_id, tournament_id, kind, team_id, stage, tournament_match_id, stake, odds)
  VALUES (v_user, p_tournament, p_kind, p_team, p_stage, p_match, p_stake, p_odds)
  RETURNING id INTO v_id;

  RETURN v_id;
END; $$;

-- 6. championship_start: draw R16 and enter booking phase
CREATE OR REPLACE FUNCTION public.championship_start(p_tournament uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
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
    WHERE COALESCE(sport, 'generic') = v_sport
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

-- 7. championship_autostart mirrors start but without admin check (called by tick)
CREATE OR REPLACE FUNCTION public.championship_autostart(p_tournament uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_teams UUID[]; v_gap INT; v_live INT; v_book INT; i INT; v_kind TEXT; v_sport TEXT;
BEGIN
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
    WHERE COALESCE(sport, 'generic') = v_sport
    ORDER BY random() LIMIT 16
  ) INTO v_teams;

  IF array_length(v_teams, 1) IS NULL OR array_length(v_teams, 1) < 16 THEN RETURN; END IF;

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
END; $$;

-- 8. Helper: generate one commentary event for a match this tick
CREATE OR REPLACE FUNCTION public.champ_gen_event(
  p_match_id uuid, p_sport text, p_minute int
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  m RECORD;
  na TEXT; nb TEXT;
  v_r NUMERIC := random();
  v_side TEXT; v_scorer TEXT; v_type TEXT; v_text TEXT;
  v_events jsonb;
  v_goal BOOLEAN := false;
BEGIN
  SELECT tm.*, ta.name AS name_a, tb.name AS name_b
    INTO m
    FROM public.tournament_matches tm
    LEFT JOIN public.teams ta ON ta.id = tm.participant_a_id
    LEFT JOIN public.teams tb ON tb.id = tm.participant_b_id
   WHERE tm.id = p_match_id;

  na := COALESCE(m.name_a, 'A'); nb := COALESCE(m.name_b, 'B');
  v_side := CASE WHEN random() < 0.5 THEN 'a' ELSE 'b' END;
  v_scorer := CASE WHEN v_side = 'a' THEN na ELSE nb END;

  IF v_r < 0.22 THEN
    v_goal := true; v_type := 'goal';
    v_text := CASE WHEN p_sport = 'football'
      THEN v_scorer || ' scores! ' || (ARRAY['Clinical finish','Screamer from range','Header from the corner','Tap-in at the far post','Curling free-kick'])[floor(random()*5+1)]
      ELSE v_scorer || ' strikes! ' || (ARRAY['Ruthless','Clinical','Devastating hit'])[floor(random()*3+1)] END;
  ELSIF v_r < 0.45 THEN
    v_type := 'chance'; v_text := v_scorer || CASE WHEN p_sport='football' THEN ' — shot just wide!' ELSE ' — close call!' END;
  ELSIF v_r < 0.65 THEN
    v_type := 'save'; v_text := (CASE WHEN v_side='a' THEN nb ELSE na END) || CASE WHEN p_sport='football' THEN ' keeper pulls off a great save' ELSE ' block!' END;
  ELSIF v_r < 0.78 THEN
    v_type := 'card'; v_text := v_scorer || CASE WHEN p_sport='football' THEN ' booked for a cynical foul' ELSE ' takes a penalty' END;
  ELSE
    v_type := 'possession'; v_text := v_scorer || CASE WHEN p_sport='football' THEN ' controlling midfield tempo' ELSE ' presses forward' END;
  END IF;

  v_events := COALESCE(m.live_events, '[]'::jsonb) || jsonb_build_object(
    'at', extract(epoch from now()),
    'minute', p_minute,
    'type', v_type,
    'side', v_side,
    'text', v_text
  );

  UPDATE public.tournament_matches
     SET live_events = v_events,
         score_a = CASE WHEN v_goal AND v_side = 'a' THEN COALESCE(score_a, 0) + 1 ELSE COALESCE(score_a, 0) END,
         score_b = CASE WHEN v_goal AND v_side = 'b' THEN COALESCE(score_b, 0) + 1 ELSE COALESCE(score_b, 0) END,
         updated_at = now()
   WHERE id = p_match_id;
END; $$;

-- 9. Rewrite championship_tick to handle booking → live → gap → next stage
CREATE OR REPLACE FUNCTION public.championship_tick()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  t RECORD; m RECORD;
  v_stage TEXT; v_next_stage TEXT; v_next_round INT;
  v_winner UUID; v_winners UUID[]; v_gap INT; v_live INT;
  v_champ UUID; v_runner UUID;
  advanced INT := 0; i INT; v_auto BOOLEAN; v_open BOOLEAN;
  v_new_tid UUID; v_sport TEXT; v_minute INT;
  v_kickoff_events jsonb;
BEGIN
  -- Auto-start scheduled tournaments whose starts_at has arrived
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'scheduled'
       AND starts_at IS NOT NULL AND starts_at <= now()
     ORDER BY starts_at ASC LIMIT 3
  LOOP
    PERFORM public.championship_autostart(t.id);
    advanced := advanced + 1;
  END LOOP;

  -- Booking phase: flip to live when booking window closes, kick off current stage
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'booking'
       AND booking_closes_at IS NOT NULL
       AND booking_closes_at <= now()
     ORDER BY booking_closes_at ASC LIMIT 5
  LOOP
    v_sport := CASE WHEN t.kind='championship_football' THEN 'football' ELSE 'generic' END;
    v_live := COALESCE(t.stage_live_seconds, 30);

    UPDATE public.tournament_matches
       SET status = 'live',
           live_started_at = now(),
           live_events = jsonb_build_array(jsonb_build_object(
             'at', extract(epoch from now()), 'minute', 0, 'type', 'kickoff',
             'text', CASE WHEN v_sport='football' THEN 'Kick-off!' ELSE 'Fight begins!' END
           ))
     WHERE tournament_id = t.id AND round_name = t.current_stage AND status = 'pending';

    UPDATE public.tournaments
       SET status = 'live',
           stage_live_ends_at = now() + (v_live || ' seconds')::interval,
           next_stage_at = NULL,
           updated_at = now()
     WHERE id = t.id;
    advanced := advanced + 1;
  END LOOP;

  -- Live stage in progress: generate commentary
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'live'
       AND stage_live_ends_at IS NOT NULL
       AND stage_live_ends_at > now()
     LIMIT 5
  LOOP
    v_sport := CASE WHEN t.kind='championship_football' THEN 'football' ELSE 'generic' END;
    v_live := COALESCE(t.stage_live_seconds, 30);
    -- Compressed match minute 0..90 based on how much of the stage has elapsed
    v_minute := LEAST(90, GREATEST(1, (
      90 * (v_live - GREATEST(0, EXTRACT(epoch FROM (t.stage_live_ends_at - now()))::int)) / GREATEST(1, v_live)
    )::int));

    FOR m IN
      SELECT id FROM public.tournament_matches
       WHERE tournament_id = t.id AND round_name = t.current_stage AND status = 'live'
    LOOP
      PERFORM public.champ_gen_event(m.id, v_sport, v_minute);
    END LOOP;
    advanced := advanced + 1;
  END LOOP;

  -- Live stage ended: settle scores, then either wait for gap or start next stage
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'live'
       AND stage_live_ends_at IS NOT NULL
       AND stage_live_ends_at <= now()
       AND next_stage_at IS NULL
     LIMIT 5
  LOOP
    v_stage := t.current_stage;
    v_gap := COALESCE(t.stage_gap_seconds, 20);
    v_sport := CASE WHEN t.kind='championship_football' THEN 'football' ELSE 'generic' END;

    -- Finalize any remaining live matches
    FOR m IN
      SELECT * FROM public.tournament_matches
       WHERE tournament_id = t.id AND round_name = v_stage AND status = 'live'
       ORDER BY slot ASC
    LOOP
      -- Ensure a decisive score: if tied, give one more goal to whoever led events
      IF COALESCE(m.score_a, 0) = COALESCE(m.score_b, 0) THEN
        IF random() < 0.5 THEN
          UPDATE public.tournament_matches SET score_a = COALESCE(score_a,0) + 1 WHERE id = m.id;
        ELSE
          UPDATE public.tournament_matches SET score_b = COALESCE(score_b,0) + 1 WHERE id = m.id;
        END IF;
      END IF;
    END LOOP;

    -- Now compute winners & mark completed
    v_winners := ARRAY[]::UUID[];
    FOR m IN
      SELECT * FROM public.tournament_matches
       WHERE tournament_id = t.id AND round_name = v_stage AND status = 'live'
       ORDER BY slot ASC
    LOOP
      v_winner := CASE WHEN COALESCE(m.score_a,0) > COALESCE(m.score_b,0) THEN m.participant_a_id ELSE m.participant_b_id END;
      UPDATE public.tournament_matches
         SET winner_id = v_winner,
             status = 'completed',
             live_events = COALESCE(live_events, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
               'at', extract(epoch from now()), 'minute', 90, 'type', 'fulltime',
               'text', CASE WHEN v_sport='football' THEN 'Full time' ELSE 'Match over' END
             )),
             updated_at = now()
       WHERE id = m.id;
      v_winners := v_winners || v_winner;

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id = v_winner THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id = v_winner THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_match_id = m.id AND kind='match_winner' AND status='pending';
    END LOOP;

    -- Settle eliminated_at for this stage
    UPDATE public.championship_bets
       SET status = CASE WHEN team_id IN (
             SELECT CASE WHEN tm.winner_id = tm.participant_a_id THEN tm.participant_b_id ELSE tm.participant_a_id END
               FROM public.tournament_matches tm
              WHERE tm.tournament_id = t.id AND tm.round_name = v_stage
           ) THEN 'won' ELSE 'lost' END,
           payout = CASE WHEN team_id IN (
             SELECT CASE WHEN tm.winner_id = tm.participant_a_id THEN tm.participant_b_id ELSE tm.participant_a_id END
               FROM public.tournament_matches tm
              WHERE tm.tournament_id = t.id AND tm.round_name = v_stage
           ) THEN (stake*odds)::BIGINT ELSE 0 END,
           settled_at = now()
     WHERE tournament_id = t.id AND kind='eliminated_at' AND stage=v_stage AND status='pending';

    v_next_stage := CASE v_stage WHEN 'R16' THEN 'QF' WHEN 'QF' THEN 'SF' WHEN 'SF' THEN 'F' ELSE NULL END;
    v_next_round := CASE v_stage WHEN 'R16' THEN 2 WHEN 'QF' THEN 3 WHEN 'SF' THEN 4 ELSE NULL END;

    IF v_next_stage IS NULL THEN
      -- Championship over
      v_champ := v_winners[1];
      SELECT CASE WHEN tm.winner_id = tm.participant_a_id THEN tm.participant_b_id ELSE tm.participant_a_id END
        INTO v_runner FROM public.tournament_matches tm
       WHERE tm.tournament_id = t.id AND tm.round_name = 'F' LIMIT 1;

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id = v_champ THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id = v_champ THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_id = t.id AND kind='outright' AND status='pending';

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (SELECT unnest(ARRAY[v_champ, v_runner])) THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id IN (SELECT unnest(ARRAY[v_champ, v_runner])) THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_id = t.id AND kind='reach_final' AND status='pending';

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (SELECT winner_id FROM public.tournament_matches WHERE tournament_id=t.id AND round_name='QF' AND winner_id IS NOT NULL) THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id IN (SELECT winner_id FROM public.tournament_matches WHERE tournament_id=t.id AND round_name='QF' AND winner_id IS NOT NULL) THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_id=t.id AND kind='reach_semi' AND status='pending';

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (SELECT winner_id FROM public.tournament_matches WHERE tournament_id=t.id AND round_name='R16' AND winner_id IS NOT NULL) THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id IN (SELECT winner_id FROM public.tournament_matches WHERE tournament_id=t.id AND round_name='R16' AND winner_id IS NOT NULL) THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_id=t.id AND kind='reach_quarter' AND status='pending';

      PERFORM public.credit_championship_payouts(t.id);

      UPDATE public.tournaments
         SET status='completed', current_stage='F',
             champion_team_id = v_champ, runner_up_team_id = v_runner,
             next_stage_at = NULL, stage_live_ends_at = NULL,
             updated_at = now()
       WHERE id = t.id;

      SELECT virtual_championship_auto_restart,
             CASE WHEN t.kind='championship_football'
                  THEN virtual_championship_football_enabled
                  ELSE virtual_championship_enabled END
        INTO v_auto, v_open
        FROM public.app_settings WHERE id=1;

      IF v_auto AND v_open THEN
        INSERT INTO public.tournaments (name, kind, status, starts_at, stage_gap_seconds, bracket_size, current_stage)
        VALUES (
          CASE WHEN t.kind='championship_football' THEN 'Auto Football Cup ' ELSE 'Auto Championship ' END
            || to_char(now(), 'Mon DD HH24:MI'),
          t.kind, 'scheduled', now() + interval '30 seconds', v_gap, 16, 'R16'
        ) RETURNING id INTO v_new_tid;
        PERFORM public.championship_autostart(v_new_tid);
      END IF;
    ELSE
      -- Draw next stage pairings; enter gap phase
      FOR i IN 0..(array_length(v_winners,1)/2 - 1) LOOP
        INSERT INTO public.tournament_matches (tournament_id, round, round_name, slot, participant_a_id, participant_b_id, status, score_a, score_b)
        VALUES (t.id, v_next_round, v_next_stage, i, v_winners[i*2+1], v_winners[i*2+2], 'pending', 0, 0);
      END LOOP;

      UPDATE public.tournaments
         SET current_stage = v_next_stage,
             next_stage_at = now() + (v_gap || ' seconds')::interval,
             stage_live_ends_at = NULL,
             updated_at = now()
       WHERE id = t.id;
    END IF;
    advanced := advanced + 1;
  END LOOP;

  -- Gap ended: kick off the next stage (pending → live)
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'live'
       AND next_stage_at IS NOT NULL
       AND next_stage_at <= now()
       AND stage_live_ends_at IS NULL
     LIMIT 5
  LOOP
    v_sport := CASE WHEN t.kind='championship_football' THEN 'football' ELSE 'generic' END;
    v_live := COALESCE(t.stage_live_seconds, 30);

    UPDATE public.tournament_matches
       SET status = 'live',
           live_started_at = now(),
           live_events = jsonb_build_array(jsonb_build_object(
             'at', extract(epoch from now()), 'minute', 0, 'type', 'kickoff',
             'text', CASE WHEN v_sport='football' THEN 'Kick-off!' ELSE 'Fight begins!' END
           ))
     WHERE tournament_id = t.id AND round_name = t.current_stage AND status = 'pending';

    UPDATE public.tournaments
       SET stage_live_ends_at = now() + (v_live || ' seconds')::interval,
           next_stage_at = NULL,
           updated_at = now()
     WHERE id = t.id;
    advanced := advanced + 1;
  END LOOP;

  RETURN jsonb_build_object('advanced', advanced);
END; $$;
