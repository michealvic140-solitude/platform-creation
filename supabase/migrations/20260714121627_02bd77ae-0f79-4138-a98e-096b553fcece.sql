
-- ============================================================
-- TRACK A: CHAMPIONSHIP VIRTUAL - BRACKET ENGINE
-- ============================================================

ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS bracket JSONB,
  ADD COLUMN IF NOT EXISTS next_stage_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS champion_team_id UUID,
  ADD COLUMN IF NOT EXISTS runner_up_team_id UUID,
  ADD COLUMN IF NOT EXISTS team_ids UUID[];

-- Championship bets: dedicated table so we don't disturb the main bets flow.
CREATE TABLE IF NOT EXISTS public.championship_bets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('outright','reach_final','reach_semi','reach_quarter','eliminated_at','match_winner')),
  team_id UUID,
  stage TEXT,
  tournament_match_id UUID REFERENCES public.tournament_matches(id) ON DELETE SET NULL,
  stake BIGINT NOT NULL CHECK (stake > 0),
  odds NUMERIC(8,2) NOT NULL CHECK (odds > 0),
  payout BIGINT NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','won','lost','void')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  settled_at TIMESTAMPTZ
);

GRANT SELECT, INSERT ON public.championship_bets TO authenticated;
GRANT ALL ON public.championship_bets TO service_role;

ALTER TABLE public.championship_bets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users view own championship bets" ON public.championship_bets
  FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Users insert own championship bets" ON public.championship_bets
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_champ_bets_tournament ON public.championship_bets(tournament_id, status);
CREATE INDEX IF NOT EXISTS idx_champ_bets_user ON public.championship_bets(user_id, created_at DESC);

-- ============================================================
-- championship_start(tournament_id)
-- Admin-callable. Seeds 16 random teams, builds bracket, R16 matches.
-- ============================================================
CREATE OR REPLACE FUNCTION public.championship_start(p_tournament UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_teams UUID[];
  v_gap INT;
  v_bracket JSONB;
  i INT;
  v_slot INT;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin'::app_role) AND NOT public.has_role(auth.uid(), 'super_admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can start championships';
  END IF;

  SELECT ARRAY(SELECT id FROM public.teams ORDER BY random() LIMIT 16) INTO v_teams;
  IF array_length(v_teams, 1) IS NULL OR array_length(v_teams, 1) < 16 THEN
    RAISE EXCEPTION 'Need at least 16 teams to run a championship (found %)', COALESCE(array_length(v_teams, 1), 0);
  END IF;

  SELECT COALESCE(stage_gap_seconds, 20) INTO v_gap FROM public.tournaments WHERE id = p_tournament;

  -- Build R16 pairings JSONB
  v_bracket := jsonb_build_object('stages', jsonb_build_object());

  DELETE FROM public.tournament_matches WHERE tournament_id = p_tournament;

  FOR i IN 0..7 LOOP
    INSERT INTO public.tournament_matches (
      tournament_id, round, round_name, slot, participant_a_id, participant_b_id, status
    ) VALUES (
      p_tournament, 1, 'R16', i, v_teams[i*2 + 1], v_teams[i*2 + 2], 'pending'
    );
  END LOOP;

  UPDATE public.tournaments
     SET status = 'live',
         current_stage = 'R16',
         team_ids = v_teams,
         next_stage_at = now() + (v_gap || ' seconds')::interval,
         starts_at = COALESCE(starts_at, now()),
         updated_at = now()
   WHERE id = p_tournament;

  RETURN jsonb_build_object('ok', true, 'tournament_id', p_tournament);
END;
$$;

REVOKE ALL ON FUNCTION public.championship_start(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.championship_start(UUID) TO authenticated, service_role;

-- ============================================================
-- championship_tick() - public heartbeat
-- Advances stages, simulates shootouts, settles bets.
-- ============================================================
CREATE OR REPLACE FUNCTION public.championship_tick()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  t RECORD;
  m RECORD;
  v_stage TEXT;
  v_next_stage TEXT;
  v_next_round INT;
  v_winner UUID;
  v_score_a INT;
  v_score_b INT;
  v_winners UUID[];
  v_gap INT;
  v_champ UUID;
  v_runner UUID;
  advanced INT := 0;
BEGIN
  FOR t IN
    SELECT * FROM public.tournaments
     WHERE kind = 'championship_virtual'
       AND status = 'live'
       AND next_stage_at IS NOT NULL
       AND next_stage_at <= now()
     ORDER BY next_stage_at ASC
     LIMIT 5
  LOOP
    v_stage := t.current_stage;
    v_gap := COALESCE(t.stage_gap_seconds, 20);

    -- 1. Simulate current stage matches
    v_winners := ARRAY[]::UUID[];
    FOR m IN
      SELECT * FROM public.tournament_matches
       WHERE tournament_id = t.id
         AND round_name = v_stage
         AND status = 'pending'
       ORDER BY slot ASC
    LOOP
      v_score_a := (floor(random() * 5) + 1)::INT;
      v_score_b := (floor(random() * 5) + 1)::INT;
      -- Ensure no draw
      IF v_score_a = v_score_b THEN
        IF random() < 0.5 THEN v_score_a := v_score_a + 1; ELSE v_score_b := v_score_b + 1; END IF;
      END IF;
      IF v_score_a > v_score_b THEN v_winner := m.participant_a_id;
      ELSE v_winner := m.participant_b_id; END IF;

      UPDATE public.tournament_matches
         SET score_a = v_score_a, score_b = v_score_b,
             winner_id = v_winner, status = 'completed',
             updated_at = now()
       WHERE id = m.id;

      v_winners := v_winners || v_winner;

      -- Settle per-match_winner bets on this match
      UPDATE public.championship_bets
         SET status = CASE WHEN team_id = v_winner THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id = v_winner THEN (stake * odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_match_id = m.id
         AND kind = 'match_winner'
         AND status = 'pending';
    END LOOP;

    -- Settle eliminated_at for teams eliminated in this stage
    UPDATE public.championship_bets
       SET status = CASE WHEN team_id = ANY (
             SELECT CASE WHEN tm.winner_id = tm.participant_a_id THEN tm.participant_b_id ELSE tm.participant_a_id END
             FROM public.tournament_matches tm
             WHERE tm.tournament_id = t.id AND tm.round_name = v_stage
           ) THEN 'won' ELSE 'lost' END,
           payout = CASE WHEN team_id = ANY (
             SELECT CASE WHEN tm.winner_id = tm.participant_a_id THEN tm.participant_b_id ELSE tm.participant_a_id END
             FROM public.tournament_matches tm
             WHERE tm.tournament_id = t.id AND tm.round_name = v_stage
           ) THEN (stake * odds)::BIGINT ELSE 0 END,
           settled_at = now()
     WHERE tournament_id = t.id
       AND kind = 'eliminated_at'
       AND stage = v_stage
       AND status = 'pending';

    -- Determine next stage
    v_next_stage := CASE v_stage
      WHEN 'R16' THEN 'QF'
      WHEN 'QF' THEN 'SF'
      WHEN 'SF' THEN 'F'
      ELSE NULL END;
    v_next_round := CASE v_stage WHEN 'R16' THEN 2 WHEN 'QF' THEN 3 WHEN 'SF' THEN 4 ELSE NULL END;

    IF v_next_stage IS NULL THEN
      -- Final done. v_winners has 1 entry = champion
      v_champ := v_winners[1];
      -- Runner-up = loser of final
      SELECT CASE WHEN tm.winner_id = tm.participant_a_id THEN tm.participant_b_id ELSE tm.participant_a_id END
        INTO v_runner
        FROM public.tournament_matches tm
       WHERE tm.tournament_id = t.id AND tm.round_name = 'F'
       LIMIT 1;

      -- Settle outright: won if team_id = champion
      UPDATE public.championship_bets
         SET status = CASE WHEN team_id = v_champ THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id = v_champ THEN (stake * odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_id = t.id AND kind = 'outright' AND status = 'pending';

      -- Settle reach_final: won if team was in Final (either finalist)
      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (v_champ, v_runner) THEN 'won' ELSE 'lost' END,
             payout = CASE WHEN team_id IN (v_champ, v_runner) THEN (stake * odds)::BIGINT ELSE 0 END,
             settled_at = now()
       WHERE tournament_id = t.id AND kind = 'reach_final' AND status = 'pending';

      -- reach_semi: winners of QF
      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (
             SELECT winner_id FROM public.tournament_matches
              WHERE tournament_id = t.id AND round_name = 'QF' AND winner_id IS NOT NULL
           ) THEN 'won' ELSE 'lost' END,
           payout = CASE WHEN team_id IN (
             SELECT winner_id FROM public.tournament_matches
              WHERE tournament_id = t.id AND round_name = 'QF' AND winner_id IS NOT NULL
           ) THEN (stake * odds)::BIGINT ELSE 0 END,
           settled_at = now()
       WHERE tournament_id = t.id AND kind = 'reach_semi' AND status = 'pending';

      -- reach_quarter: winners of R16
      UPDATE public.championship_bets
         SET status = CASE WHEN team_id IN (
             SELECT winner_id FROM public.tournament_matches
              WHERE tournament_id = t.id AND round_name = 'R16' AND winner_id IS NOT NULL
           ) THEN 'won' ELSE 'lost' END,
           payout = CASE WHEN team_id IN (
             SELECT winner_id FROM public.tournament_matches
              WHERE tournament_id = t.id AND round_name = 'R16' AND winner_id IS NOT NULL
           ) THEN (stake * odds)::BIGINT ELSE 0 END,
           settled_at = now()
       WHERE tournament_id = t.id AND kind = 'reach_quarter' AND status = 'pending';

      -- Credit winners
      PERFORM public.credit_championship_payouts(t.id);

      UPDATE public.tournaments
         SET status = 'completed',
             current_stage = 'F',
             champion_team_id = v_champ,
             runner_up_team_id = v_runner,
             next_stage_at = NULL,
             updated_at = now()
       WHERE id = t.id;
    ELSE
      -- Build next round matches from v_winners in order
      FOR i IN 0..(array_length(v_winners, 1)/2 - 1) LOOP
        INSERT INTO public.tournament_matches (
          tournament_id, round, round_name, slot, participant_a_id, participant_b_id, status
        ) VALUES (
          t.id, v_next_round, v_next_stage, i, v_winners[i*2 + 1], v_winners[i*2 + 2], 'pending'
        );
      END LOOP;

      UPDATE public.tournaments
         SET current_stage = v_next_stage,
             next_stage_at = now() + (v_gap || ' seconds')::interval,
             updated_at = now()
       WHERE id = t.id;
    END IF;

    advanced := advanced + 1;
  END LOOP;

  RETURN jsonb_build_object('advanced', advanced);
END;
$$;

REVOKE ALL ON FUNCTION public.championship_tick() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.championship_tick() TO authenticated, service_role, anon;

-- Helper to credit winning championship bets into user token_balance.
CREATE OR REPLACE FUNCTION public.credit_championship_payouts(p_tournament UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b RECORD;
BEGIN
  FOR b IN
    SELECT user_id, SUM(payout) AS total
      FROM public.championship_bets
     WHERE tournament_id = p_tournament
       AND status = 'won'
       AND payout > 0
     GROUP BY user_id
  LOOP
    UPDATE public.profiles SET token_balance = token_balance + b.total WHERE id = b.user_id;
    INSERT INTO public.token_transactions (user_id, amount, kind, description)
      VALUES (b.user_id, b.total, 'championship_win', 'Championship Virtual payout')
      ON CONFLICT DO NOTHING;
  END LOOP;
END;
$$;

-- Debit + record a championship bet
CREATE OR REPLACE FUNCTION public.place_championship_bet(
  p_tournament UUID,
  p_kind TEXT,
  p_team UUID,
  p_stage TEXT,
  p_match UUID,
  p_stake BIGINT,
  p_odds NUMERIC
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_bal BIGINT;
  v_id UUID;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_stake <= 0 THEN RAISE EXCEPTION 'Invalid stake'; END IF;

  SELECT token_balance INTO v_bal FROM public.profiles WHERE id = v_user FOR UPDATE;
  IF v_bal IS NULL OR v_bal < p_stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  UPDATE public.profiles SET token_balance = token_balance - p_stake WHERE id = v_user;

  INSERT INTO public.championship_bets (user_id, tournament_id, kind, team_id, stage, tournament_match_id, stake, odds)
  VALUES (v_user, p_tournament, p_kind, p_team, p_stage, p_match, p_stake, p_odds)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.place_championship_bet(UUID,TEXT,UUID,TEXT,UUID,BIGINT,NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_championship_bet(UUID,TEXT,UUID,TEXT,UUID,BIGINT,NUMERIC) TO authenticated;

-- ============================================================
-- TRACK B: PER-USER INSTANT VIRTUAL ROUNDS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_virtual_rounds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  match_label TEXT NOT NULL,
  side TEXT NOT NULL CHECK (side IN ('home','away')),
  stake BIGINT NOT NULL CHECK (stake > 0),
  odds NUMERIC(6,2) NOT NULL DEFAULT 1.90,
  home_kicks BOOLEAN[] NOT NULL,
  away_kicks BOOLEAN[] NOT NULL,
  home_score INT NOT NULL,
  away_score INT NOT NULL,
  result TEXT NOT NULL CHECK (result IN ('won','lost')),
  payout BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT ON public.user_virtual_rounds TO authenticated;
GRANT ALL ON public.user_virtual_rounds TO service_role;

ALTER TABLE public.user_virtual_rounds ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users view own virtual rounds" ON public.user_virtual_rounds
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_user_vr ON public.user_virtual_rounds(user_id, created_at DESC);

-- Deterministic-random shootout: 5 kicks each, seeded server-side.
CREATE OR REPLACE FUNCTION public.start_user_virtual_round(
  p_home TEXT,
  p_away TEXT,
  p_side TEXT,
  p_stake BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_bal BIGINT;
  v_home BOOLEAN[] := ARRAY[]::BOOLEAN[];
  v_away BOOLEAN[] := ARRAY[]::BOOLEAN[];
  v_hs INT := 0;
  v_as INT := 0;
  i INT;
  v_result TEXT;
  v_payout BIGINT := 0;
  v_odds NUMERIC := 1.90;
  v_id UUID;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_side NOT IN ('home','away') THEN RAISE EXCEPTION 'Invalid side'; END IF;
  IF p_stake <= 0 THEN RAISE EXCEPTION 'Invalid stake'; END IF;

  SELECT token_balance INTO v_bal FROM public.profiles WHERE id = v_user FOR UPDATE;
  IF v_bal IS NULL OR v_bal < p_stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  UPDATE public.profiles SET token_balance = token_balance - p_stake WHERE id = v_user;

  FOR i IN 1..5 LOOP
    v_home := v_home || (random() < 0.75);
    v_away := v_away || (random() < 0.75);
    IF v_home[i] THEN v_hs := v_hs + 1; END IF;
    IF v_away[i] THEN v_as := v_as + 1; END IF;
  END LOOP;

  -- No draws: sudden-death coinflip
  WHILE v_hs = v_as LOOP
    v_home := v_home || (random() < 0.75);
    v_away := v_away || (random() < 0.75);
    IF v_home[array_length(v_home,1)] THEN v_hs := v_hs + 1; END IF;
    IF v_away[array_length(v_away,1)] THEN v_as := v_as + 1; END IF;
  END LOOP;

  IF (p_side = 'home' AND v_hs > v_as) OR (p_side = 'away' AND v_as > v_hs) THEN
    v_result := 'won';
    v_payout := (p_stake * v_odds)::BIGINT;
    UPDATE public.profiles SET token_balance = token_balance + v_payout WHERE id = v_user;
  ELSE
    v_result := 'lost';
  END IF;

  INSERT INTO public.user_virtual_rounds (
    user_id, match_label, side, stake, odds, home_kicks, away_kicks, home_score, away_score, result, payout
  ) VALUES (
    v_user, p_home || ' vs ' || p_away, p_side, p_stake, v_odds, v_home, v_away, v_hs, v_as, v_result, v_payout
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id,
    'home_kicks', v_home,
    'away_kicks', v_away,
    'home_score', v_hs,
    'away_score', v_as,
    'result', v_result,
    'payout', v_payout
  );
END;
$$;

REVOKE ALL ON FUNCTION public.start_user_virtual_round(TEXT,TEXT,TEXT,BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_user_virtual_round(TEXT,TEXT,TEXT,BIGINT) TO authenticated;
