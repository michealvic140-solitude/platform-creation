CREATE OR REPLACE FUNCTION public.sync_future_contender_scores()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  home_name text;
  away_name text;
BEGIN
  SELECT COALESCE(NULLIF(trim(p.name), ''), NULLIF(trim(t.name), ''))
    INTO home_name
  FROM (SELECT NEW.home_player_id AS player_id, NEW.home_team_id AS team_id) s
  LEFT JOIN public.players p ON p.id = s.player_id
  LEFT JOIN public.teams t ON t.id = s.team_id;

  SELECT COALESCE(NULLIF(trim(p.name), ''), NULLIF(trim(t.name), ''))
    INTO away_name
  FROM (SELECT NEW.away_player_id AS player_id, NEW.away_team_id AS team_id) s
  LEFT JOIN public.players p ON p.id = s.player_id
  LEFT JOIN public.teams t ON t.id = s.team_id;

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

UPDATE public.odds o
SET future_live_opponent = CASE
    WHEN o.future_match_side = 'away' THEN COALESCE(NULLIF(trim(hp.name), ''), NULLIF(trim(ht.name), ''))
    ELSE COALESCE(NULLIF(trim(ap.name), ''), NULLIF(trim(at.name), ''))
  END,
  updated_at = now()
FROM public.matches m
LEFT JOIN public.players hp ON hp.id = m.home_player_id
LEFT JOIN public.players ap ON ap.id = m.away_player_id
LEFT JOIN public.teams ht ON ht.id = m.home_team_id
LEFT JOIN public.teams at ON at.id = m.away_team_id
WHERE o.future_match_id = m.id
  AND m.match_kind <> 'future';