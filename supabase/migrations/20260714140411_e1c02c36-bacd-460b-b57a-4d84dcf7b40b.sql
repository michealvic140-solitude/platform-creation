
-- 1. Fix super_admin enum error in championship_start
CREATE OR REPLACE FUNCTION public.championship_start(p_tournament UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_teams UUID[]; v_gap INT; i INT; v_kind TEXT; v_sport TEXT;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can start championships';
  END IF;

  SELECT kind, COALESCE(stage_gap_seconds, 20) INTO v_kind, v_gap
    FROM public.tournaments WHERE id = p_tournament;
  v_sport := CASE WHEN v_kind = 'championship_football' THEN 'football' ELSE 'generic' END;

  SELECT ARRAY(
    SELECT id FROM public.teams
    WHERE COALESCE(sport,'generic') = v_sport
    ORDER BY random() LIMIT 16
  ) INTO v_teams;

  IF array_length(v_teams,1) IS NULL OR array_length(v_teams,1) < 16 THEN
    RAISE EXCEPTION 'Need at least 16 % teams (found %). Tag more teams as % in Clans admin.',
      v_sport, COALESCE(array_length(v_teams,1),0), v_sport;
  END IF;

  DELETE FROM public.tournament_matches WHERE tournament_id = p_tournament;
  FOR i IN 0..7 LOOP
    INSERT INTO public.tournament_matches (tournament_id, round, round_name, slot, participant_a_id, participant_b_id, status)
    VALUES (p_tournament, 1, 'R16', i, v_teams[i*2+1], v_teams[i*2+2], 'pending');
  END LOOP;

  UPDATE public.tournaments
     SET status='live', current_stage='R16', team_ids=v_teams,
         next_stage_at = now() + (v_gap || ' seconds')::interval,
         starts_at = COALESCE(starts_at, now()), updated_at = now()
   WHERE id = p_tournament;

  RETURN jsonb_build_object('ok', true, 'tournament_id', p_tournament, 'sport', v_sport);
END;
$$;

-- 2. Sport columns
ALTER TABLE public.teams ADD COLUMN IF NOT EXISTS sport TEXT NOT NULL DEFAULT 'generic';
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS sport TEXT NOT NULL DEFAULT 'generic';
CREATE INDEX IF NOT EXISTS idx_teams_sport ON public.teams(sport);

-- 3. App settings additions
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS virtual_championship_football_enabled BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS virtual_football_instant_enabled BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS virtual_championship_auto_restart BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS platform_logo_corner_url TEXT,
  ADD COLUMN IF NOT EXISTS auth_hero_image_url TEXT;

-- 4. Bulk delete teams (avoids per-row statement timeout)
CREATE OR REPLACE FUNCTION public.delete_teams_bulk(p_ids UUID[])
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_count INT;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can bulk-delete teams';
  END IF;
  IF p_ids IS NULL OR array_length(p_ids,1) IS NULL THEN
    RETURN jsonb_build_object('deleted', 0);
  END IF;

  SET LOCAL statement_timeout = '60s';

  DELETE FROM public.bet_selections
    WHERE match_id IN (SELECT id FROM public.matches WHERE home_team_id = ANY(p_ids) OR away_team_id = ANY(p_ids));
  DELETE FROM public.odds
    WHERE match_id IN (SELECT id FROM public.matches WHERE home_team_id = ANY(p_ids) OR away_team_id = ANY(p_ids));
  DELETE FROM public.matches WHERE home_team_id = ANY(p_ids) OR away_team_id = ANY(p_ids);
  DELETE FROM public.tournament_matches WHERE participant_a_id = ANY(p_ids) OR participant_b_id = ANY(p_ids);
  DELETE FROM public.players WHERE team_id = ANY(p_ids);
  DELETE FROM public.teams WHERE id = ANY(p_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('deleted', v_count);
END;
$$;
REVOKE ALL ON FUNCTION public.delete_teams_bulk(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_teams_bulk(UUID[]) TO authenticated;

-- 5. Auto-restart-aware tick for BOTH kinds
CREATE OR REPLACE FUNCTION public.championship_tick()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  t RECORD; m RECORD;
  v_stage TEXT; v_next_stage TEXT; v_next_round INT;
  v_winner UUID; v_score_a INT; v_score_b INT;
  v_winners UUID[]; v_gap INT; v_champ UUID; v_runner UUID;
  advanced INT := 0; i INT;
  v_auto BOOLEAN; v_open BOOLEAN;
  v_new_tid UUID;
BEGIN
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind IN ('championship_virtual','championship_football')
       AND status = 'live'
       AND next_stage_at IS NOT NULL
       AND next_stage_at <= now()
     ORDER BY next_stage_at ASC LIMIT 5
  LOOP
    v_stage := t.current_stage;
    v_gap := COALESCE(t.stage_gap_seconds, 20);
    v_winners := ARRAY[]::UUID[];

    FOR m IN
      SELECT * FROM public.tournament_matches
       WHERE tournament_id = t.id AND round_name = v_stage AND status = 'pending'
       ORDER BY slot ASC
    LOOP
      v_score_a := (floor(random()*5)+1)::INT;
      v_score_b := (floor(random()*5)+1)::INT;
      IF v_score_a = v_score_b THEN
        IF random() < 0.5 THEN v_score_a := v_score_a+1; ELSE v_score_b := v_score_b+1; END IF;
      END IF;
      v_winner := CASE WHEN v_score_a > v_score_b THEN m.participant_a_id ELSE m.participant_b_id END;

      UPDATE public.tournament_matches
         SET score_a=v_score_a, score_b=v_score_b, winner_id=v_winner, status='completed', updated_at=now()
       WHERE id = m.id;

      v_winners := v_winners || v_winner;

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id = v_winner THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id = v_winner THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_match_id = m.id AND kind='match_winner' AND status='pending';
    END LOOP;

    UPDATE public.championship_bets
       SET status = CASE WHEN team_id = ANY (
             SELECT CASE WHEN tm.winner_id = tm.participant_a_id THEN tm.participant_b_id ELSE tm.participant_a_id END
             FROM public.tournament_matches tm
             WHERE tm.tournament_id = t.id AND tm.round_name = v_stage
           ) THEN 'won' ELSE 'lost' END,
           payout = CASE WHEN team_id = ANY (
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
       WHERE tm.tournament_id = t.id AND tm.round_name='F' LIMIT 1;

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id=v_champ THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id=v_champ THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_id=t.id AND kind='outright' AND status='pending';

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (v_champ,v_runner) THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id IN (v_champ,v_runner) THEN (stake*odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_id=t.id AND kind='reach_final' AND status='pending';

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (
             SELECT winner_id FROM public.tournament_matches
              WHERE tournament_id=t.id AND round_name='QF' AND winner_id IS NOT NULL
           ) THEN 'won' ELSE 'lost' END,
           payout = CASE WHEN team_id IN (
             SELECT winner_id FROM public.tournament_matches
              WHERE tournament_id=t.id AND round_name='QF' AND winner_id IS NOT NULL
           ) THEN (stake*odds)::BIGINT ELSE 0 END,
           settled_at = now()
       WHERE tournament_id=t.id AND kind='reach_semi' AND status='pending';

      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (
             SELECT winner_id FROM public.tournament_matches
              WHERE tournament_id=t.id AND round_name='R16' AND winner_id IS NOT NULL
           ) THEN 'won' ELSE 'lost' END,
           payout = CASE WHEN team_id IN (
             SELECT winner_id FROM public.tournament_matches
              WHERE tournament_id=t.id AND round_name='R16' AND winner_id IS NOT NULL
           ) THEN (stake*odds)::BIGINT ELSE 0 END,
           settled_at = now()
       WHERE tournament_id=t.id AND kind='reach_quarter' AND status='pending';

      PERFORM public.credit_championship_payouts(t.id);

      UPDATE public.tournaments
         SET status='completed', current_stage='F',
             champion_team_id=v_champ, runner_up_team_id=v_runner,
             next_stage_at=NULL, updated_at=now()
       WHERE id = t.id;

      -- Auto-restart: schedule a fresh tournament of the same kind
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
        -- Draft immediately so it flips live on its next tick
        PERFORM public.championship_autostart(v_new_tid);
      END IF;
    ELSE
      FOR i IN 0..(array_length(v_winners,1)/2 - 1) LOOP
        INSERT INTO public.tournament_matches (tournament_id, round, round_name, slot, participant_a_id, participant_b_id, status)
        VALUES (t.id, v_next_round, v_next_stage, i, v_winners[i*2+1], v_winners[i*2+2], 'pending');
      END LOOP;

      UPDATE public.tournaments
         SET current_stage=v_next_stage,
             next_stage_at = now() + (v_gap || ' seconds')::interval,
             updated_at=now()
       WHERE id = t.id;
    END IF;

    advanced := advanced + 1;
  END LOOP;

  -- Also auto-start any scheduled tournament whose starts_at has arrived
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

  RETURN jsonb_build_object('advanced', advanced);
END;
$$;

-- 6. Internal auto-drafter (no admin check — called only by tick)
CREATE OR REPLACE FUNCTION public.championship_autostart(p_tournament UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_teams UUID[]; v_gap INT; i INT; v_kind TEXT; v_sport TEXT;
BEGIN
  SELECT kind, COALESCE(stage_gap_seconds,20) INTO v_kind, v_gap
    FROM public.tournaments WHERE id = p_tournament;
  v_sport := CASE WHEN v_kind='championship_football' THEN 'football' ELSE 'generic' END;

  SELECT ARRAY(
    SELECT id FROM public.teams
    WHERE COALESCE(sport,'generic') = v_sport
    ORDER BY random() LIMIT 16
  ) INTO v_teams;

  IF array_length(v_teams,1) IS NULL OR array_length(v_teams,1) < 16 THEN
    RETURN; -- skip silently; admin will see it stuck as scheduled
  END IF;

  DELETE FROM public.tournament_matches WHERE tournament_id = p_tournament;
  FOR i IN 0..7 LOOP
    INSERT INTO public.tournament_matches (tournament_id, round, round_name, slot, participant_a_id, participant_b_id, status)
    VALUES (p_tournament, 1, 'R16', i, v_teams[i*2+1], v_teams[i*2+2], 'pending');
  END LOOP;

  UPDATE public.tournaments
     SET status='live', current_stage='R16', team_ids=v_teams,
         next_stage_at = now() + (v_gap || ' seconds')::interval,
         updated_at = now()
   WHERE id = p_tournament;
END;
$$;
REVOKE ALL ON FUNCTION public.championship_autostart(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.championship_autostart(UUID) TO service_role;

REVOKE ALL ON FUNCTION public.championship_tick() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.championship_tick() TO authenticated, service_role, anon;
