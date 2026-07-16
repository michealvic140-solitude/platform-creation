-- 1) Fix delete_teams_bulk: odds table has no match_id, cascade via markets.match_id
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
    WHERE match_id IN (
      SELECT id FROM public.matches
      WHERE home_team_id = ANY(p_ids) OR away_team_id = ANY(p_ids)
    );
  DELETE FROM public.odds
    WHERE market_id IN (
      SELECT mk.id FROM public.markets mk
      JOIN public.matches m ON m.id = mk.match_id
      WHERE m.home_team_id = ANY(p_ids) OR m.away_team_id = ANY(p_ids)
    );
  DELETE FROM public.markets
    WHERE match_id IN (
      SELECT id FROM public.matches
      WHERE home_team_id = ANY(p_ids) OR away_team_id = ANY(p_ids)
    );
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

-- 2) Bulk delete players (admin)
CREATE OR REPLACE FUNCTION public.delete_players_bulk(p_ids UUID[])
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_count INT;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can bulk-delete players';
  END IF;
  IF p_ids IS NULL OR array_length(p_ids,1) IS NULL THEN
    RETURN jsonb_build_object('deleted', 0);
  END IF;
  SET LOCAL statement_timeout = '30s';
  DELETE FROM public.players WHERE id = ANY(p_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('deleted', v_count);
END;
$$;
REVOKE ALL ON FUNCTION public.delete_players_bulk(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_players_bulk(UUID[]) TO authenticated;

-- 3) Cancel/withdraw a championship bet while the tournament is still in booking phase.
CREATE OR REPLACE FUNCTION public.cancel_championship_bet(p_tournament UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_bet public.championship_bets%ROWTYPE;
  v_status TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;
  SELECT status INTO v_status FROM public.tournaments WHERE id = p_tournament;
  IF v_status IS DISTINCT FROM 'booking' THEN
    RAISE EXCEPTION 'Booking is closed for this championship';
  END IF;
  SELECT * INTO v_bet FROM public.championship_bets
    WHERE user_id = auth.uid() AND tournament_id = p_tournament
    LIMIT 1;
  IF v_bet.id IS NULL THEN
    RETURN jsonb_build_object('cancelled', 0);
  END IF;
  -- refund stake
  UPDATE public.profiles SET tokens = COALESCE(tokens,0) + v_bet.stake WHERE id = auth.uid();
  DELETE FROM public.championship_bets WHERE id = v_bet.id;
  RETURN jsonb_build_object('cancelled', 1, 'refunded', v_bet.stake);
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_championship_bet(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_championship_bet(UUID) TO authenticated;