
ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS is_virtual boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS lock_time timestamptz NULL,
  ADD COLUMN IF NOT EXISTS virtual_first_blood_team_id uuid NULL;

CREATE INDEX IF NOT EXISTS idx_matches_is_virtual ON public.matches(is_virtual, start_time DESC);

INSERT INTO public.categories (name, icon)
SELECT 'Virtual Gangs', '🎲'
WHERE NOT EXISTS (SELECT 1 FROM public.categories WHERE name = 'Virtual Gangs');

CREATE OR REPLACE FUNCTION public.resolve_virtual_round(
  _match_id uuid,
  _home_score int,
  _away_score int,
  _first_blood_team_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  m record;
  mk record;
  total_kills int := _home_score + _away_score;
  winner_team_id uuid;
  winner_label text;
  cs_label text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO m FROM matches WHERE id = _match_id FOR UPDATE;
  IF m IS NULL THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF NOT m.is_virtual THEN RAISE EXCEPTION 'Not a virtual round'; END IF;

  IF _home_score > _away_score THEN winner_team_id := m.home_team_id;
  ELSIF _away_score > _home_score THEN winner_team_id := m.away_team_id;
  ELSE winner_team_id := NULL; END IF;

  cs_label := _home_score || ':' || _away_score;

  -- Reset winners
  UPDATE odds o SET is_winner = false
    FROM markets mm WHERE o.market_id = mm.id AND mm.match_id = _match_id;

  FOR mk IN SELECT * FROM markets WHERE match_id = _match_id LOOP
    IF lower(mk.name) LIKE '%match winner%' OR lower(mk.name) = '1x2' THEN
      IF winner_team_id IS NULL THEN winner_label := 'Draw';
      ELSIF winner_team_id = m.home_team_id THEN
        SELECT name INTO winner_label FROM teams WHERE id = m.home_team_id;
      ELSE
        SELECT name INTO winner_label FROM teams WHERE id = m.away_team_id;
      END IF;
      UPDATE odds SET is_winner = (label = winner_label) WHERE market_id = mk.id;

    ELSIF lower(mk.name) LIKE '%first blood%' THEN
      IF _first_blood_team_id IS NOT NULL THEN
        SELECT name INTO winner_label FROM teams WHERE id = _first_blood_team_id;
        UPDATE odds SET is_winner = (label = winner_label) WHERE market_id = mk.id;
      END IF;

    ELSIF lower(mk.name) LIKE '%total kills%' OR lower(mk.name) LIKE '%over/under%' THEN
      UPDATE odds o SET is_winner = CASE
        WHEN lower(o.label) LIKE 'over %' AND total_kills::numeric > NULLIF(regexp_replace(o.label, '[^0-9.]', '', 'g'), '')::numeric THEN true
        WHEN lower(o.label) LIKE 'under %' AND total_kills::numeric < NULLIF(regexp_replace(o.label, '[^0-9.]', '', 'g'), '')::numeric THEN true
        ELSE false END
      WHERE o.market_id = mk.id;

    ELSIF lower(mk.name) LIKE '%correct score%' THEN
      UPDATE odds SET is_winner = (replace(label, ' ', '') = cs_label) WHERE market_id = mk.id;
    END IF;
  END LOOP;

  -- Mark match ended; existing settlement logic / admin payout pipeline takes over
  UPDATE matches SET
    status = 'ended',
    home_score = _home_score,
    away_score = _away_score,
    winner_team_id = winner_team_id,
    virtual_first_blood_team_id = _first_blood_team_id,
    updated_at = now()
  WHERE id = _match_id;

  -- Settle bets attached to this match: win if every selection on this match is a winner
  -- and no selection on any other match is a loser; lose if any selection on this match is a loser.
  -- For instant virtuals (single-match tickets are typical), this is straightforward.
  WITH bet_ids AS (
    SELECT DISTINCT bs.bet_id FROM bet_selections bs WHERE bs.match_id = _match_id
  ),
  bet_status AS (
    SELECT b.id AS bet_id,
      bool_or(o.is_winner IS FALSE AND o.is_winner IS NOT NULL AND m2.status = 'ended') AS has_loser,
      bool_and(o.is_winner IS TRUE) AS all_winners,
      count(*) FILTER (WHERE m2.status <> 'ended') AS unsettled
    FROM bets b
    JOIN bet_selections bs ON bs.bet_id = b.id
    JOIN odds o ON o.id = bs.odd_id
    JOIN markets mm2 ON mm2.id = bs.market_id
    JOIN matches m2 ON m2.id = bs.match_id
    WHERE b.id IN (SELECT bet_id FROM bet_ids) AND b.status = 'open'
    GROUP BY b.id
  )
  UPDATE bets b SET
    status = CASE WHEN bs.has_loser THEN 'lost'::bet_status
                  WHEN bs.all_winners AND bs.unsettled = 0 THEN 'won'::bet_status
                  ELSE b.status END,
    settled_at = CASE WHEN bs.has_loser OR (bs.all_winners AND bs.unsettled = 0) THEN now() ELSE b.settled_at END
  FROM bet_status bs WHERE b.id = bs.bet_id;

  -- Credit winners
  WITH won_bets AS (
    SELECT b.id, b.user_id, b.potential_payout FROM bets b
    JOIN bet_selections bs ON bs.bet_id = b.id
    WHERE bs.match_id = _match_id AND b.status = 'won' AND b.settled_at IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM token_transactions tt WHERE tt.user_id = b.user_id AND tt.kind = 'bet_win' AND tt.description LIKE '%' || b.tracking_id || '%')
  )
  UPDATE profiles p SET token_balance = p.token_balance + wb.potential_payout
  FROM won_bets wb WHERE p.id = wb.user_id;

  INSERT INTO token_transactions(user_id, amount, balance_after, kind, description)
  SELECT b.user_id, b.potential_payout,
    (SELECT token_balance FROM profiles WHERE id = b.user_id),
    'bet_win', 'Win: ' || b.tracking_id
  FROM bets b
  JOIN bet_selections bs ON bs.bet_id = b.id
  WHERE bs.match_id = _match_id AND b.status = 'won' AND b.settled_at IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM token_transactions tt WHERE tt.user_id = b.user_id AND tt.kind = 'bet_win' AND tt.description = 'Win: ' || b.tracking_id);

  RETURN jsonb_build_object('ok', true, 'winner_team_id', winner_team_id, 'total_kills', total_kills);
END $$;
