CREATE OR REPLACE FUNCTION public.sync_future_contender_scores()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  home_player_name text;
  away_player_name text;
  home_team_name text;
  away_team_name text;
  home_name text;
  away_name text;
BEGIN
  SELECT NULLIF(trim(p.name), ''), NULLIF(trim(t.name), '')
    INTO home_player_name, home_team_name
  FROM (SELECT NEW.home_player_id AS player_id, NEW.home_team_id AS team_id) s
  LEFT JOIN public.players p ON p.id = s.player_id
  LEFT JOIN public.teams t ON t.id = s.team_id;

  SELECT NULLIF(trim(p.name), ''), NULLIF(trim(t.name), '')
    INTO away_player_name, away_team_name
  FROM (SELECT NEW.away_player_id AS player_id, NEW.away_team_id AS team_id) s
  LEFT JOIN public.players p ON p.id = s.player_id
  LEFT JOIN public.teams t ON t.id = s.team_id;

  home_name := COALESCE(home_player_name, home_team_name, 'Home');
  away_name := COALESCE(away_player_name, away_team_name, 'Away');

  UPDATE public.odds o
  SET
    future_match_id = NEW.id,
    future_match_side = side_match.side,
    future_live_score = CASE WHEN side_match.side = 'away'
      THEN COALESCE(NEW.away_score,0) || '-' || COALESCE(NEW.home_score,0)
      ELSE COALESCE(NEW.home_score,0) || '-' || COALESCE(NEW.away_score,0) END,
    future_live_opponent = CASE WHEN side_match.side = 'away' THEN home_name ELSE away_name END,
    future_live_outcome = CASE
      WHEN NEW.status::text NOT IN ('ended','completed','settled') THEN 'pending'
      WHEN NEW.winner_team_id IS NOT NULL AND side_match.side = 'away' AND NEW.winner_team_id = NEW.away_team_id THEN 'won'
      WHEN NEW.winner_team_id IS NOT NULL AND side_match.side = 'home' AND NEW.winner_team_id = NEW.home_team_id THEN 'won'
      WHEN NEW.winner_team_id IS NOT NULL THEN 'lost'
      WHEN side_match.side = 'away' AND COALESCE(NEW.away_score,0) > COALESCE(NEW.home_score,0) THEN 'won'
      WHEN side_match.side = 'home' AND COALESCE(NEW.home_score,0) > COALESCE(NEW.away_score,0) THEN 'won'
      WHEN COALESCE(NEW.home_score,0) <> COALESCE(NEW.away_score,0) THEN 'lost'
      ELSE 'pending'
    END,
    updated_at = now()
  FROM public.markets mk
  JOIN public.matches fm ON fm.id = mk.match_id
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN lower(trim(o.label)) IN (lower(home_player_name), lower(home_team_name)) THEN 'home'
      WHEN lower(trim(o.label)) IN (lower(away_player_name), lower(away_team_name)) THEN 'away'
      ELSE NULL
    END AS side
  ) side_match
  WHERE o.market_id = mk.id
    AND fm.match_kind = 'future'
    AND fm.is_archived = false
    AND side_match.side IS NOT NULL;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_future_contender_scores ON public.matches;
CREATE TRIGGER trg_sync_future_contender_scores
AFTER UPDATE OF home_score, away_score, status, winner_team_id ON public.matches
FOR EACH ROW EXECUTE FUNCTION public.sync_future_contender_scores();

WITH candidate_links AS (
  SELECT
    o.id AS odd_id,
    m.id AS match_id,
    CASE
      WHEN lower(trim(o.label)) IN (lower(NULLIF(trim(hp.name), '')), lower(NULLIF(trim(ht.name), ''))) THEN 'home'
      WHEN lower(trim(o.label)) IN (lower(NULLIF(trim(ap.name), '')), lower(NULLIF(trim(at.name), ''))) THEN 'away'
    END AS side,
    COALESCE(NULLIF(trim(hp.name), ''), NULLIF(trim(ht.name), ''), 'Home') AS home_name,
    COALESCE(NULLIF(trim(ap.name), ''), NULLIF(trim(at.name), ''), 'Away') AS away_name,
    m.home_score,
    m.away_score,
    m.status,
    m.winner_team_id,
    m.home_team_id,
    m.away_team_id,
    row_number() OVER (PARTITION BY o.id ORDER BY m.start_time DESC NULLS LAST, m.updated_at DESC NULLS LAST, m.created_at DESC) AS rn
  FROM public.odds o
  JOIN public.markets mk ON mk.id = o.market_id
  JOIN public.matches fm ON fm.id = mk.match_id
  JOIN public.matches m ON m.match_kind <> 'future' AND m.is_virtual = false AND m.is_archived = false
  LEFT JOIN public.players hp ON hp.id = m.home_player_id
  LEFT JOIN public.players ap ON ap.id = m.away_player_id
  LEFT JOIN public.teams ht ON ht.id = m.home_team_id
  LEFT JOIN public.teams at ON at.id = m.away_team_id
  WHERE fm.match_kind = 'future'
    AND fm.is_archived = false
    AND lower(trim(o.label)) IN (
      lower(NULLIF(trim(hp.name), '')),
      lower(NULLIF(trim(ap.name), '')),
      lower(NULLIF(trim(ht.name), '')),
      lower(NULLIF(trim(at.name), ''))
    )
), best_links AS (
  SELECT * FROM candidate_links WHERE rn = 1 AND side IS NOT NULL
)
UPDATE public.odds o
SET
  future_match_id = b.match_id,
  future_match_side = b.side,
  future_live_score = CASE WHEN b.side = 'away'
    THEN COALESCE(b.away_score,0) || '-' || COALESCE(b.home_score,0)
    ELSE COALESCE(b.home_score,0) || '-' || COALESCE(b.away_score,0) END,
  future_live_opponent = CASE WHEN b.side = 'away' THEN b.home_name ELSE b.away_name END,
  future_live_outcome = CASE
    WHEN b.status::text NOT IN ('ended','completed','settled') THEN 'pending'
    WHEN b.winner_team_id IS NOT NULL AND b.side = 'away' AND b.winner_team_id = b.away_team_id THEN 'won'
    WHEN b.winner_team_id IS NOT NULL AND b.side = 'home' AND b.winner_team_id = b.home_team_id THEN 'won'
    WHEN b.winner_team_id IS NOT NULL THEN 'lost'
    WHEN b.side = 'away' AND COALESCE(b.away_score,0) > COALESCE(b.home_score,0) THEN 'won'
    WHEN b.side = 'home' AND COALESCE(b.home_score,0) > COALESCE(b.away_score,0) THEN 'won'
    WHEN COALESCE(b.home_score,0) <> COALESCE(b.away_score,0) THEN 'lost'
    ELSE 'pending'
  END,
  updated_at = now()
FROM best_links b
WHERE o.id = b.odd_id;

REVOKE ALL ON FUNCTION public.sync_future_contender_scores() FROM PUBLIC, anon, authenticated;