
-- Auto-sync scores from public.matches into tournament_matches
-- when the two seeded tournament participants correspond to the home/away players
-- of an active (non-settled) normal match. Admin still manually marks
-- won / lost / qualified / disqualified.

CREATE OR REPLACE FUNCTION public.sync_match_scores_to_tournament()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tm RECORD;
  pa_player uuid;
  pb_player uuid;
BEGIN
  -- only react to score-bearing changes
  IF TG_OP = 'UPDATE'
     AND NEW.home_score IS NOT DISTINCT FROM OLD.home_score
     AND NEW.away_score IS NOT DISTINCT FROM OLD.away_score THEN
    RETURN NEW;
  END IF;

  IF NEW.home_player_id IS NULL OR NEW.away_player_id IS NULL THEN
    RETURN NEW;
  END IF;

  FOR tm IN
    SELECT m.id, m.participant_a_id, m.participant_b_id,
           pa.player_id AS pa_player_id,
           pb.player_id AS pb_player_id
    FROM public.tournament_matches m
    LEFT JOIN public.tournament_participants pa ON pa.id = m.participant_a_id
    LEFT JOIN public.tournament_participants pb ON pb.id = m.participant_b_id
    WHERE m.participant_a_id IS NOT NULL
      AND m.participant_b_id IS NOT NULL
      AND COALESCE(m.status,'pending') NOT IN ('qualified','disqualified','won','lost','completed')
      AND m.winner_id IS NULL
      AND (
        (pa.player_id = NEW.home_player_id AND pb.player_id = NEW.away_player_id)
        OR
        (pa.player_id = NEW.away_player_id AND pb.player_id = NEW.home_player_id)
      )
  LOOP
    IF tm.pa_player_id = NEW.home_player_id THEN
      UPDATE public.tournament_matches
        SET score_a = NEW.home_score,
            score_b = NEW.away_score,
            kills_a = NEW.home_score,
            kills_b = NEW.away_score,
            updated_at = now()
        WHERE id = tm.id;
    ELSE
      UPDATE public.tournament_matches
        SET score_a = NEW.away_score,
            score_b = NEW.home_score,
            kills_a = NEW.away_score,
            kills_b = NEW.home_score,
            updated_at = now()
        WHERE id = tm.id;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_match_scores_to_tournament ON public.matches;
CREATE TRIGGER trg_sync_match_scores_to_tournament
AFTER INSERT OR UPDATE OF home_score, away_score ON public.matches
FOR EACH ROW
EXECUTE FUNCTION public.sync_match_scores_to_tournament();
