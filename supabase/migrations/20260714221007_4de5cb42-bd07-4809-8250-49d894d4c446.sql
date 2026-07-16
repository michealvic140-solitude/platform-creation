CREATE OR REPLACE FUNCTION public.championship_autostart(p_tournament uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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

  -- Teams tagged as 'both' are eligible for either football or generic championships.
  SELECT ARRAY(
    SELECT id FROM public.teams
     WHERE COALESCE(sport, 'generic') IN (v_sport, 'both')
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
END; $function$;

-- Kick the currently-stuck tournaments so they transition immediately.
SELECT public.championship_tick();