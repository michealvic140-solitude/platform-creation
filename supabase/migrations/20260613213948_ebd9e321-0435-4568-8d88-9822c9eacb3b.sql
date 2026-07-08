ALTER TABLE public.tournament_matches
  ADD COLUMN IF NOT EXISTS match_id uuid REFERENCES public.matches(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS result_label text;

ALTER TABLE public.tournament_participants
  ADD COLUMN IF NOT EXISTS is_disqualified boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_tmatch_match_id ON public.tournament_matches(match_id);

CREATE OR REPLACE FUNCTION public.sync_tournament_match_scores()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.tournament_matches tm
    SET score_a = NEW.home_score,
        score_b = NEW.away_score,
        status = CASE WHEN tm.status = 'completed' THEN tm.status ELSE 'live' END,
        updated_at = now()
  WHERE tm.match_id = NEW.id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_tournament_scores ON public.matches;
CREATE TRIGGER trg_sync_tournament_scores
AFTER UPDATE OF home_score, away_score, status ON public.matches
FOR EACH ROW EXECUTE FUNCTION public.sync_tournament_match_scores();

CREATE OR REPLACE FUNCTION public.set_tournament_result(
  _match_id uuid, _score_a integer, _score_b integer, _winner_id uuid,
  _outcome text DEFAULT NULL, _dq_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE m record; loser uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO m FROM public.tournament_matches WHERE id = _match_id FOR UPDATE;
  IF m IS NULL THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF _winner_id IS NOT NULL AND _winner_id <> m.participant_a_id AND _winner_id <> m.participant_b_id THEN
    RAISE EXCEPTION 'Winner must be one of the two participants';
  END IF;

  UPDATE public.tournament_matches
    SET score_a = _score_a, score_b = _score_b, winner_id = _winner_id,
        result_label = _outcome,
        status = CASE WHEN _winner_id IS NOT NULL THEN 'completed' ELSE 'live' END,
        updated_at = now()
    WHERE id = _match_id;

  IF m.participant_a_id IS NOT NULL THEN
    UPDATE public.tournament_participants SET is_disqualified = false WHERE id = m.participant_a_id;
  END IF;
  IF m.participant_b_id IS NOT NULL THEN
    UPDATE public.tournament_participants SET is_disqualified = false WHERE id = m.participant_b_id;
  END IF;

  IF _winner_id IS NOT NULL THEN
    loser := CASE WHEN _winner_id = m.participant_a_id THEN m.participant_b_id ELSE m.participant_a_id END;
    IF loser IS NOT NULL THEN
      UPDATE public.tournament_participants
        SET is_eliminated = true, eliminated_round = m.round,
            is_disqualified = (loser = _dq_id)
        WHERE id = loser;
    END IF;
    UPDATE public.tournament_participants SET current_round = m.round + 1, is_eliminated = false WHERE id = _winner_id;

    IF m.next_match_id IS NOT NULL THEN
      IF m.next_slot = 'a' THEN
        UPDATE public.tournament_matches SET participant_a_id = _winner_id, updated_at = now() WHERE id = m.next_match_id;
      ELSE
        UPDATE public.tournament_matches SET participant_b_id = _winner_id, updated_at = now() WHERE id = m.next_match_id;
      END IF;
    ELSE
      UPDATE public.tournaments SET champion_id = _winner_id, status = 'completed', updated_at = now() WHERE id = m.tournament_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true);
END $function$;