CREATE OR REPLACE FUNCTION public.sync_future_contender_scores()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  home_name text;
  away_name text;
  home_player text;
  away_player text;
BEGIN
  SELECT t.name INTO home_name FROM public.teams t WHERE t.id = NEW.home_team_id;
  SELECT t.name INTO away_name FROM public.teams t WHERE t.id = NEW.away_team_id;
  SELECT p.name INTO home_player FROM public.players p WHERE p.id = NEW.home_player_id;
  SELECT p.name INTO away_player FROM public.players p WHERE p.id = NEW.away_player_id;

  -- Prefer the actual shooter/player name; fall back to the team/gang name.
  home_name := COALESCE(home_player, home_name);
  away_name := COALESCE(away_player, away_name);

  UPDATE public.odds o
  SET
    future_live_score = CASE WHEN o.future_match_side = 'away'
      THEN COALESCE(NEW.away_score,0) || '-' || COALESCE(NEW.home_score,0)
      ELSE COALESCE(NEW.home_score,0) || '-' || COALESCE(NEW.away_score,0) END,
    future_live_opponent = CASE WHEN o.future_match_side = 'away' THEN home_name ELSE away_name END,
    future_live_outcome = CASE
      WHEN NEW.status::text NOT IN ('ended','completed','settled') OR NEW.winner_team_id IS NULL THEN 'pending'
      WHEN (o.future_match_side = 'away' AND NEW.winner_team_id = NEW.away_team_id)
        OR (COALESCE(o.future_match_side,'home') <> 'away' AND NEW.winner_team_id = NEW.home_team_id) THEN 'won'
      ELSE 'lost' END,
    updated_at = now()
  WHERE o.future_match_id = NEW.id;

  RETURN NEW;
END;
$function$;