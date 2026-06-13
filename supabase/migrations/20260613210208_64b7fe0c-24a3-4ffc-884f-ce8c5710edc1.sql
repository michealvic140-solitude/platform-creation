
CREATE OR REPLACE FUNCTION public.sync_match_scores_to_tournament()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  tm record;
  pa_player uuid;
  pb_player uuid;
BEGIN
  -- Require both players assigned on the source match
  IF NEW.home_player_id IS NULL OR NEW.away_player_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Only react when scores or players actually changed (or on insert)
  IF TG_OP = 'UPDATE'
     AND OLD.home_score IS NOT DISTINCT FROM NEW.home_score
     AND OLD.away_score IS NOT DISTINCT FROM NEW.away_score
     AND OLD.home_player_id IS NOT DISTINCT FROM NEW.home_player_id
     AND OLD.away_player_id IS NOT DISTINCT FROM NEW.away_player_id THEN
    RETURN NEW;
  END IF;

  -- Find every pending tournament match whose two seeded participants
  -- match this normal match's two players (in either orientation).
  FOR tm IN
    SELECT m.id, m.participant_a_id, m.participant_b_id,
           pa.player_id AS pa_player_id, pb.player_id AS pb_player_id
    FROM public.tournament_matches m
    JOIN public.tournament_participants pa ON pa.id = m.participant_a_id
    JOIN public.tournament_participants pb ON pb.id = m.participant_b_id
    WHERE m.status = 'pending'
      AND m.winner_id IS NULL
      AND (
        (pa.player_id = NEW.home_player_id AND pb.player_id = NEW.away_player_id)
        OR
        (pa.player_id = NEW.away_player_id AND pb.player_id = NEW.home_player_id)
      )
  LOOP
    IF tm.pa_player_id = NEW.home_player_id THEN
      UPDATE public.tournament_matches
        SET kills_a = NEW.home_score, kills_b = NEW.away_score, updated_at = now()
        WHERE id = tm.id;
    ELSE
      UPDATE public.tournament_matches
        SET kills_a = NEW.away_score, kills_b = NEW.home_score, updated_at = now()
        WHERE id = tm.id;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_match_scores_to_tournament ON public.matches;
CREATE TRIGGER trg_sync_match_scores_to_tournament
AFTER INSERT OR UPDATE OF home_score, away_score, home_player_id, away_player_id
ON public.matches
FOR EACH ROW
EXECUTE FUNCTION public.sync_match_scores_to_tournament();

-- Backfill once for any currently-pending tournament matches whose players already played
UPDATE public.tournament_matches tm
SET kills_a = CASE WHEN pa.player_id = mm.home_player_id THEN mm.home_score ELSE mm.away_score END,
    kills_b = CASE WHEN pa.player_id = mm.home_player_id THEN mm.away_score ELSE mm.home_score END,
    updated_at = now()
FROM public.tournament_participants pa,
     public.tournament_participants pb,
     public.matches mm
WHERE tm.status = 'pending'
  AND tm.winner_id IS NULL
  AND pa.id = tm.participant_a_id
  AND pb.id = tm.participant_b_id
  AND mm.home_player_id IS NOT NULL
  AND mm.away_player_id IS NOT NULL
  AND (
    (pa.player_id = mm.home_player_id AND pb.player_id = mm.away_player_id)
    OR (pa.player_id = mm.away_player_id AND pb.player_id = mm.home_player_id)
  );
