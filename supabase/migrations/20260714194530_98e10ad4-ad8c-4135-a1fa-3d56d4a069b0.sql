
-- Extend championship_tick to bootstrap a new cup when none exists
-- and the feature is enabled. Auto-restart previously only fired when a cup
-- completed, so first-time users saw "No cup scheduled" forever.

CREATE OR REPLACE FUNCTION public.championship_bootstrap_if_needed()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
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

  -- Generic (gang) cup
  IF COALESCE(s.virtual_championship_enabled, false) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.tournaments
       WHERE kind = 'championship_virtual'
         AND status IN ('scheduled','booking','live')
    ) THEN
      SELECT COUNT(*) INTO v_teams FROM public.teams WHERE COALESCE(sport,'generic')='generic';
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

  -- Football cup
  IF COALESCE(s.virtual_championship_football_enabled, false) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.tournaments
       WHERE kind = 'championship_football'
         AND status IN ('scheduled','booking','live')
    ) THEN
      SELECT COUNT(*) INTO v_teams FROM public.teams WHERE COALESCE(sport,'generic')='football';
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

REVOKE ALL ON FUNCTION public.championship_bootstrap_if_needed() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.championship_bootstrap_if_needed() TO authenticated, service_role, anon;

-- Patch championship_tick to run bootstrap at the top of every tick
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
BEGIN
  -- Bootstrap: spawn a cup if none exists and the mode is enabled
  advanced := advanced + public.championship_bootstrap_if_needed();

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

  -- Booking phase → live
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
       SET status = 'live', live_started_at = now(),
           live_events = jsonb_build_array(jsonb_build_object(
             'at', extract(epoch from now()), 'minute', 0, 'type', 'kickoff',
             'text', CASE WHEN v_sport='football' THEN 'Kick-off!' ELSE 'Fight begins!' END))
     WHERE tournament_id = t.id AND round_name = t.current_stage AND status = 'pending';

    UPDATE public.tournaments
       SET status = 'live', stage_live_ends_at = now() + (v_live || ' seconds')::interval,
           next_stage_at = NULL, updated_at = now()
     WHERE id = t.id;
    advanced := advanced + 1;
  END LOOP;

  -- Live in progress: generate commentary
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'live' AND stage_live_ends_at IS NOT NULL AND stage_live_ends_at > now()
     LIMIT 5
  LOOP
    v_sport := CASE WHEN t.kind='championship_football' THEN 'football' ELSE 'generic' END;
    v_live := COALESCE(t.stage_live_seconds, 30);
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

  -- Live ended: settle, then gap or next stage
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'live' AND stage_live_ends_at IS NOT NULL AND stage_live_ends_at <= now()
       AND next_stage_at IS NULL
     LIMIT 5
  LOOP
    v_stage := t.current_stage;
    v_gap := COALESCE(t.stage_gap_seconds, 20);
    v_sport := CASE WHEN t.kind='championship_football' THEN 'football' ELSE 'generic' END;

    FOR m IN
      SELECT * FROM public.tournament_matches
       WHERE tournament_id = t.id AND round_name = v_stage AND status = 'live' ORDER BY slot ASC
    LOOP
      IF COALESCE(m.score_a, 0) = COALESCE(m.score_b, 0) THEN
        IF random() < 0.5 THEN
          UPDATE public.tournament_matches SET score_a = COALESCE(score_a,0) + 1 WHERE id = m.id;
        ELSE
          UPDATE public.tournament_matches SET score_b = COALESCE(score_b,0) + 1 WHERE id = m.id;
        END IF;
      END IF;
    END LOOP;

    v_winners := ARRAY[]::UUID[];
    FOR m IN
      SELECT * FROM public.tournament_matches
       WHERE tournament_id = t.id AND round_name = v_stage AND status = 'live' ORDER BY slot ASC
    LOOP
      v_winner := CASE WHEN COALESCE(m.score_a,0) > COALESCE(m.score_b,0) THEN m.participant_a_id ELSE m.participant_b_id END;
      UPDATE public.tournament_matches
         SET winner_id = v_winner, status = 'completed',
             live_events = COALESCE(live_events, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
               'at', extract(epoch from now()), 'minute', 90, 'type', 'fulltime',
               'text', CASE WHEN v_sport='football' THEN 'Full time' ELSE 'Match over' END)),
             updated_at = now()
       WHERE id = m.id;
      v_winners := v_winners || v_winner;

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id = v_winner THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id = v_winner THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_match_id = m.id AND kind='match_winner' AND status='pending';
    END LOOP;

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
             next_stage_at = NULL, stage_live_ends_at = NULL, updated_at = now()
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
      FOR i IN 0..(array_length(v_winners,1)/2 - 1) LOOP
        INSERT INTO public.tournament_matches (tournament_id, round, round_name, slot, participant_a_id, participant_b_id, status, score_a, score_b)
        VALUES (t.id, v_next_round, v_next_stage, i, v_winners[i*2+1], v_winners[i*2+2], 'pending', 0, 0);
      END LOOP;

      UPDATE public.tournaments
         SET current_stage = v_next_stage,
             next_stage_at = now() + (v_gap || ' seconds')::interval,
             stage_live_ends_at = NULL, updated_at = now()
       WHERE id = t.id;
    END IF;
    advanced := advanced + 1;
  END LOOP;

  -- Gap ended: kick off next stage
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'live' AND next_stage_at IS NOT NULL AND next_stage_at <= now()
       AND stage_live_ends_at IS NULL
     LIMIT 5
  LOOP
    v_sport := CASE WHEN t.kind='championship_football' THEN 'football' ELSE 'generic' END;
    v_live := COALESCE(t.stage_live_seconds, 30);

    UPDATE public.tournament_matches
       SET status = 'live', live_started_at = now(),
           live_events = jsonb_build_array(jsonb_build_object(
             'at', extract(epoch from now()), 'minute', 0, 'type', 'kickoff',
             'text', CASE WHEN v_sport='football' THEN 'Kick-off!' ELSE 'Fight begins!' END))
     WHERE tournament_id = t.id AND round_name = t.current_stage AND status = 'pending';

    UPDATE public.tournaments
       SET stage_live_ends_at = now() + (v_live || ' seconds')::interval,
           next_stage_at = NULL, updated_at = now()
     WHERE id = t.id;
    advanced := advanced + 1;
  END LOOP;

  RETURN jsonb_build_object('advanced', advanced);
END; $$;

REVOKE ALL ON FUNCTION public.championship_tick() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.championship_tick() TO authenticated, service_role, anon;
