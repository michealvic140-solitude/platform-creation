CREATE OR REPLACE FUNCTION public.sync_match_to_future_contender()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _home_name text;
  _away_name text;
  _home_score int;
  _away_score int;
  _outcome text;
  r record;
  _is_home boolean;
  _player_name text;
  _opp_name text;
  _player_score int;
  _opp_score int;
  _entry jsonb;
  _existing jsonb;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.home_score IS NOT DISTINCT FROM OLD.home_score
     AND NEW.away_score IS NOT DISTINCT FROM OLD.away_score
     AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.match_kind <> 'shooter' THEN RETURN NEW; END IF;

  SELECT name INTO _home_name FROM public.players WHERE id = NEW.home_player_id;
  SELECT name INTO _away_name FROM public.players WHERE id = NEW.away_player_id;
  IF _home_name IS NULL OR _away_name IS NULL THEN RETURN NEW; END IF;

  _home_score := COALESCE(NEW.home_score, 0);
  _away_score := COALESCE(NEW.away_score, 0);

  IF NEW.status = 'ended' THEN
    IF _home_score > _away_score THEN _outcome := 'home_win';
    ELSIF _away_score > _home_score THEN _outcome := 'away_win';
    ELSE _outcome := 'draw';
    END IF;
  ELSE
    _outcome := NEW.status;
  END IF;

  FOR r IN
    SELECT o.id, o.label, o.future_progress, o.future_status, m.id AS match_id
    FROM public.odds o
    JOIN public.markets m ON m.id = o.market_id
    JOIN public.matches mt ON mt.id = m.match_id
    WHERE mt.match_kind = 'future'
      AND mt.is_archived = false
      AND COALESCE(o.future_status,'active') NOT IN ('qualified','disqualified','lost','winner','settled')
      AND (
        lower(trim(o.label)) = lower(trim(_home_name))
        OR lower(trim(o.label)) = lower(trim(_away_name))
      )
  LOOP
    _is_home := lower(trim(r.label)) = lower(trim(_home_name));
    IF _is_home THEN
      _player_name := _home_name; _opp_name := _away_name;
      _player_score := _home_score; _opp_score := _away_score;
    ELSE
      _player_name := _away_name; _opp_name := _home_name;
      _player_score := _away_score; _opp_score := _home_score;
    END IF;

    _entry := jsonb_build_object(
      'match_id', NEW.id,
      'status', NEW.status,
      'outcome', _outcome,
      'title', COALESCE(NEW.name, _player_name || ' vs ' || _opp_name),
      'opponent', _opp_name,
      'score', _player_score::text || '-' || _opp_score::text,
      'player_score', _player_score,
      'opponent_score', _opp_score,
      'at', COALESCE(NEW.start_time, now())::text,
      'note', CASE
        WHEN NEW.status = 'ended' AND _outcome = (CASE WHEN _is_home THEN 'home_win' ELSE 'away_win' END) THEN 'Won'
        WHEN NEW.status = 'ended' THEN (CASE WHEN _outcome = 'draw' THEN 'Draw' ELSE 'Lost' END)
        WHEN NEW.status = 'live' THEN 'In progress'
        ELSE 'Scheduled' END
    );

    _existing := COALESCE(r.future_progress, '[]'::jsonb);
    -- replace any prior entry for this match_id, else append
    _existing := COALESCE((
      SELECT jsonb_agg(e) FROM jsonb_array_elements(_existing) e
      WHERE e->>'match_id' <> NEW.id::text
    ), '[]'::jsonb) || jsonb_build_array(_entry);

    UPDATE public.odds
       SET future_progress = _existing,
           future_next_title = COALESCE(NEW.name, _player_name || ' vs ' || _opp_name),
           future_next_at = NEW.start_time,
           updated_at = now()
     WHERE id = r.id;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_match_to_future_contender ON public.matches;
CREATE TRIGGER trg_sync_match_to_future_contender
AFTER INSERT OR UPDATE OF home_score, away_score, status, name, start_time
ON public.matches
FOR EACH ROW
EXECUTE FUNCTION public.sync_match_to_future_contender();