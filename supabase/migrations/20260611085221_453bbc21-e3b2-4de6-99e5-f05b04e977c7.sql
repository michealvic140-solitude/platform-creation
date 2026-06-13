
-- ===== TABLES =====
CREATE TABLE IF NOT EXISTS public.tournaments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  tagline text DEFAULT 'ONE LEAGUE. NO MERCY. RESPECT THE GAME.',
  banner_url text,
  size int NOT NULL DEFAULT 26 CHECK (size IN (8,16,26,32)),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','completed','archived')),
  starts_at timestamptz,
  champion_participant_id uuid,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.tournament_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  player_id uuid REFERENCES public.players(id) ON DELETE SET NULL,
  team_id uuid REFERENCES public.teams(id) ON DELETE SET NULL,
  display_name text NOT NULL,
  gang_tag text,
  emblem_url text,
  seed int,
  is_eliminated boolean NOT NULL DEFAULT false,
  eliminated_at_round text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.tournament_matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  round text NOT NULL CHECK (round IN ('opening','r16','qf','sf','final')),
  slot_index int NOT NULL,
  code text NOT NULL,
  participant_a_id uuid REFERENCES public.tournament_participants(id) ON DELETE SET NULL,
  participant_b_id uuid REFERENCES public.tournament_participants(id) ON DELETE SET NULL,
  kills_a int,
  kills_b int,
  winner_id uuid REFERENCES public.tournament_participants(id) ON DELETE SET NULL,
  loser_id uuid REFERENCES public.tournament_participants(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','qualified','disqualified')),
  played_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tournament_id, round, slot_index)
);

-- ===== GRANTS =====
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournaments TO authenticated;
GRANT ALL ON public.tournaments TO service_role;
GRANT SELECT ON public.tournaments TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournament_participants TO authenticated;
GRANT ALL ON public.tournament_participants TO service_role;
GRANT SELECT ON public.tournament_participants TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournament_matches TO authenticated;
GRANT ALL ON public.tournament_matches TO service_role;
GRANT SELECT ON public.tournament_matches TO anon;

-- ===== RLS =====
ALTER TABLE public.tournaments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_matches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tournaments are public readable" ON public.tournaments FOR SELECT USING (true);
CREATE POLICY "Admins manage tournaments" ON public.tournaments FOR ALL USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Participants public readable" ON public.tournament_participants FOR SELECT USING (true);
CREATE POLICY "Admins manage participants" ON public.tournament_participants FOR ALL USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "Matches public readable" ON public.tournament_matches FOR SELECT USING (true);
CREATE POLICY "Admins manage matches" ON public.tournament_matches FOR ALL USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

-- ===== UPDATED_AT TRIGGERS =====
CREATE OR REPLACE FUNCTION public.tournament_touch_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

DROP TRIGGER IF EXISTS trg_tournaments_updated ON public.tournaments;
CREATE TRIGGER trg_tournaments_updated BEFORE UPDATE ON public.tournaments
  FOR EACH ROW EXECUTE FUNCTION public.tournament_touch_updated_at();

DROP TRIGGER IF EXISTS trg_tournament_matches_updated ON public.tournament_matches;
CREATE TRIGGER trg_tournament_matches_updated BEFORE UPDATE ON public.tournament_matches
  FOR EACH ROW EXECUTE FUNCTION public.tournament_touch_updated_at();

-- ===== REALTIME =====
ALTER PUBLICATION supabase_realtime ADD TABLE public.tournaments;
ALTER PUBLICATION supabase_realtime ADD TABLE public.tournament_participants;
ALTER PUBLICATION supabase_realtime ADD TABLE public.tournament_matches;

-- ===== BRACKET GENERATION =====
-- Generate empty bracket skeleton when tournament is activated.
CREATE OR REPLACE FUNCTION public.tournament_generate_bracket(_tournament_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t record;
  opening_count int;
  r16_count int;
  qf_count int;
  sf_count int;
  i int;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO t FROM public.tournaments WHERE id = _tournament_id;
  IF t IS NULL THEN RAISE EXCEPTION 'Tournament not found'; END IF;

  DELETE FROM public.tournament_matches WHERE tournament_id = _tournament_id;

  -- determine round counts
  IF t.size = 8 THEN
    opening_count := 0; r16_count := 0; qf_count := 4; sf_count := 2;
  ELSIF t.size = 16 THEN
    opening_count := 0; r16_count := 8; qf_count := 4; sf_count := 2;
  ELSIF t.size = 26 THEN
    opening_count := 13; r16_count := 8; qf_count := 4; sf_count := 2;
  ELSIF t.size = 32 THEN
    opening_count := 16; r16_count := 8; qf_count := 4; sf_count := 2;
  ELSE
    RAISE EXCEPTION 'Unsupported size %', t.size;
  END IF;

  FOR i IN 1..opening_count LOOP
    INSERT INTO public.tournament_matches(tournament_id, round, slot_index, code)
    VALUES (_tournament_id, 'opening', i, 'M' || i);
  END LOOP;
  FOR i IN 1..r16_count LOOP
    INSERT INTO public.tournament_matches(tournament_id, round, slot_index, code)
    VALUES (_tournament_id, 'r16', i, 'R16-' || i);
  END LOOP;
  FOR i IN 1..qf_count LOOP
    INSERT INTO public.tournament_matches(tournament_id, round, slot_index, code)
    VALUES (_tournament_id, 'qf', i, 'QF' || i);
  END LOOP;
  FOR i IN 1..sf_count LOOP
    INSERT INTO public.tournament_matches(tournament_id, round, slot_index, code)
    VALUES (_tournament_id, 'sf', i, 'SF' || i);
  END LOOP;
  INSERT INTO public.tournament_matches(tournament_id, round, slot_index, code)
  VALUES (_tournament_id, 'final', 1, 'FINAL');

  RETURN jsonb_build_object('ok', true, 'opening', opening_count, 'r16', r16_count, 'qf', qf_count, 'sf', sf_count);
END $$;

-- Assign winner -> advance to next round automatically
CREATE OR REPLACE FUNCTION public.tournament_set_result(
  _match_id uuid,
  _winner_id uuid,
  _kills_a int,
  _kills_b int
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m record;
  loser_pid uuid;
  next_round text;
  next_slot int;
  next_match_id uuid;
  fill_slot text; -- 'a' or 'b'
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO m FROM public.tournament_matches WHERE id = _match_id FOR UPDATE;
  IF m IS NULL THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF m.participant_a_id IS NULL OR m.participant_b_id IS NULL THEN
    RAISE EXCEPTION 'Both shooters must be assigned before setting result';
  END IF;
  IF _winner_id <> m.participant_a_id AND _winner_id <> m.participant_b_id THEN
    RAISE EXCEPTION 'Winner must be one of the assigned shooters';
  END IF;

  loser_pid := CASE WHEN _winner_id = m.participant_a_id THEN m.participant_b_id ELSE m.participant_a_id END;

  UPDATE public.tournament_matches
    SET winner_id = _winner_id,
        loser_id = loser_pid,
        kills_a = _kills_a,
        kills_b = _kills_b,
        status = 'qualified',
        played_at = COALESCE(played_at, now())
    WHERE id = _match_id;

  -- Mark loser eliminated
  UPDATE public.tournament_participants
    SET is_eliminated = true,
        eliminated_at_round = m.round
    WHERE id = loser_pid;

  -- Compute next-round slot
  next_round := CASE m.round
    WHEN 'opening' THEN 'r16'
    WHEN 'r16' THEN 'qf'
    WHEN 'qf' THEN 'sf'
    WHEN 'sf' THEN 'final'
    ELSE NULL END;

  IF next_round IS NULL THEN
    -- This was the final
    UPDATE public.tournaments SET champion_participant_id = _winner_id, status = 'completed'
      WHERE id = m.tournament_id;
    RETURN jsonb_build_object('ok', true, 'champion', _winner_id);
  END IF;

  -- Opening->R16 mapping is 1:1 by slot_index for the first N slots.
  -- R16/QF/SF use pairwise: slot i pairs with slot i+1 (i odd) into ceil(i/2).
  IF m.round = 'opening' THEN
    next_slot := m.slot_index;
    fill_slot := 'a';
    -- For 26-player: 13 opening winners + 3 byes (16 R16 slots), opening fills R16 slots 1..13
  ELSE
    next_slot := (m.slot_index + 1) / 2;
    fill_slot := CASE WHEN m.slot_index % 2 = 1 THEN 'a' ELSE 'b' END;
  END IF;

  SELECT id INTO next_match_id FROM public.tournament_matches
    WHERE tournament_id = m.tournament_id AND round = next_round AND slot_index = next_slot;

  IF next_match_id IS NOT NULL THEN
    IF fill_slot = 'a' THEN
      UPDATE public.tournament_matches SET participant_a_id = _winner_id WHERE id = next_match_id;
    ELSE
      UPDATE public.tournament_matches SET participant_b_id = _winner_id WHERE id = next_match_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'advanced_to', next_round, 'slot', next_slot);
END $$;

-- Disqualify a shooter mid-match (admin chooses which side is out, with their score)
CREATE OR REPLACE FUNCTION public.tournament_disqualify(
  _match_id uuid,
  _disqualified_participant_id uuid,
  _kills_a int,
  _kills_b int
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m record;
  winner_pid uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO m FROM public.tournament_matches WHERE id = _match_id FOR UPDATE;
  IF m IS NULL THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF _disqualified_participant_id <> m.participant_a_id AND _disqualified_participant_id <> m.participant_b_id THEN
    RAISE EXCEPTION 'Disqualified shooter must be one of the assigned shooters';
  END IF;
  winner_pid := CASE WHEN _disqualified_participant_id = m.participant_a_id THEN m.participant_b_id ELSE m.participant_a_id END;
  -- Delegate to set_result so winner advances normally
  RETURN public.tournament_set_result(_match_id, winner_pid, _kills_a, _kills_b);
END $$;

GRANT EXECUTE ON FUNCTION public.tournament_generate_bracket(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tournament_set_result(uuid, uuid, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tournament_disqualify(uuid, uuid, int, int) TO authenticated;

-- ===== STORAGE POLICIES =====
-- event-banners
DROP POLICY IF EXISTS "event_banners_read" ON storage.objects;
DROP POLICY IF EXISTS "event_banners_admin_write" ON storage.objects;
CREATE POLICY "event_banners_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'event-banners');
CREATE POLICY "event_banners_admin_write" ON storage.objects FOR ALL
  USING (bucket_id = 'event-banners' AND public.is_admin(auth.uid()))
  WITH CHECK (bucket_id = 'event-banners' AND public.is_admin(auth.uid()));

-- bracket-emblems
DROP POLICY IF EXISTS "bracket_emblems_read" ON storage.objects;
DROP POLICY IF EXISTS "bracket_emblems_admin_write" ON storage.objects;
CREATE POLICY "bracket_emblems_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'bracket-emblems');
CREATE POLICY "bracket_emblems_admin_write" ON storage.objects FOR ALL
  USING (bucket_id = 'bracket-emblems' AND public.is_admin(auth.uid()))
  WITH CHECK (bucket_id = 'bracket-emblems' AND public.is_admin(auth.uid()));
