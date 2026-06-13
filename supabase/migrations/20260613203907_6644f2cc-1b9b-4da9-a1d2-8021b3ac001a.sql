-- Align tournament backend with the online-betting-hub repo schema without dropping data.

ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS tagline text DEFAULT 'ONE LEAGUE. NO MERCY. RESPECT THE GAME.',
  ADD COLUMN IF NOT EXISTS banner_url text,
  ADD COLUMN IF NOT EXISTS size int NOT NULL DEFAULT 26,
  ADD COLUMN IF NOT EXISTS starts_at timestamptz,
  ADD COLUMN IF NOT EXISTS champion_participant_id uuid,
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.tournaments
  ALTER COLUMN tagline SET DEFAULT 'ONE LEAGUE. NO MERCY. RESPECT THE GAME.',
  ALTER COLUMN size SET DEFAULT 26;

UPDATE public.tournaments
SET starts_at = COALESCE(starts_at, event_date)
WHERE starts_at IS NULL AND EXISTS (
  SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'tournaments' AND column_name = 'event_date'
);

ALTER TABLE public.tournament_participants
  ADD COLUMN IF NOT EXISTS player_id uuid REFERENCES public.players(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS team_id uuid REFERENCES public.teams(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS display_name text,
  ADD COLUMN IF NOT EXISTS gang_tag text,
  ADD COLUMN IF NOT EXISTS emblem_url text,
  ADD COLUMN IF NOT EXISTS seed int,
  ADD COLUMN IF NOT EXISTS is_eliminated boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS eliminated_at_round text,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

UPDATE public.tournament_participants
SET
  display_name = COALESCE(display_name, name, 'Unknown Shooter'),
  emblem_url = COALESCE(emblem_url, logo_url),
  eliminated_at_round = COALESCE(eliminated_at_round, eliminated_round::text)
WHERE display_name IS NULL OR emblem_url IS NULL OR eliminated_at_round IS NULL;

ALTER TABLE public.tournament_participants
  ALTER COLUMN display_name SET NOT NULL;

ALTER TABLE public.tournament_matches
  ADD COLUMN IF NOT EXISTS round_key text,
  ADD COLUMN IF NOT EXISTS slot_index int,
  ADD COLUMN IF NOT EXISTS code text,
  ADD COLUMN IF NOT EXISTS kills_a int,
  ADD COLUMN IF NOT EXISTS kills_b int,
  ADD COLUMN IF NOT EXISTS loser_id uuid REFERENCES public.tournament_participants(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS played_at timestamptz,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

UPDATE public.tournament_matches
SET
  round_key = COALESCE(
    round_key,
    CASE
      WHEN round::text IN ('opening','r16','qf','sf','final') THEN round::text
      WHEN lower(COALESCE(round_name, '')) LIKE '%opening%' THEN 'opening'
      WHEN lower(COALESCE(round_name, '')) LIKE '%16%' THEN 'r16'
      WHEN lower(COALESCE(round_name, '')) LIKE '%quarter%' THEN 'qf'
      WHEN lower(COALESCE(round_name, '')) LIKE '%semi%' THEN 'sf'
      WHEN lower(COALESCE(round_name, '')) LIKE '%final%' THEN 'final'
      WHEN round::text = '1' THEN 'opening'
      WHEN round::text = '2' THEN 'r16'
      WHEN round::text = '3' THEN 'qf'
      WHEN round::text = '4' THEN 'sf'
      WHEN round::text = '5' THEN 'final'
      ELSE 'opening'
    END
  ),
  slot_index = COALESCE(slot_index, NULLIF(slot, 0), 1),
  code = COALESCE(code, label, 'M' || COALESCE(NULLIF(slot, 0), slot_index, 1)::text),
  kills_a = COALESCE(kills_a, score_a),
  kills_b = COALESCE(kills_b, score_b);

ALTER TABLE public.tournament_matches
  ALTER COLUMN round_key SET NOT NULL,
  ALTER COLUMN slot_index SET NOT NULL,
  ALTER COLUMN code SET NOT NULL;

ALTER TABLE public.tournament_matches
  DROP COLUMN IF EXISTS round;
ALTER TABLE public.tournament_matches
  RENAME COLUMN round_key TO round;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tournament_matches_round_check'
  ) THEN
    ALTER TABLE public.tournament_matches
      ADD CONSTRAINT tournament_matches_round_check CHECK (round IN ('opening','r16','qf','sf','final'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tournament_matches_unique_round_slot'
  ) THEN
    ALTER TABLE public.tournament_matches
      ADD CONSTRAINT tournament_matches_unique_round_slot UNIQUE (tournament_id, round, slot_index);
  END IF;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournaments TO authenticated;
GRANT ALL ON public.tournaments TO service_role;
GRANT SELECT ON public.tournaments TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournament_participants TO authenticated;
GRANT ALL ON public.tournament_participants TO service_role;
GRANT SELECT ON public.tournament_participants TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournament_matches TO authenticated;
GRANT ALL ON public.tournament_matches TO service_role;
GRANT SELECT ON public.tournament_matches TO anon;

ALTER TABLE public.tournaments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_matches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Tournaments are public readable" ON public.tournaments;
DROP POLICY IF EXISTS "Tournaments are viewable by everyone" ON public.tournaments;
CREATE POLICY "Tournaments are public readable" ON public.tournaments FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage tournaments" ON public.tournaments;
CREATE POLICY "Admins manage tournaments" ON public.tournaments FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Participants public readable" ON public.tournament_participants;
DROP POLICY IF EXISTS "Participants viewable by everyone" ON public.tournament_participants;
CREATE POLICY "Participants public readable" ON public.tournament_participants FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage participants" ON public.tournament_participants;
CREATE POLICY "Admins manage participants" ON public.tournament_participants FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Matches public readable" ON public.tournament_matches;
DROP POLICY IF EXISTS "Bracket matches viewable by everyone" ON public.tournament_matches;
CREATE POLICY "Matches public readable" ON public.tournament_matches FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage matches" ON public.tournament_matches;
DROP POLICY IF EXISTS "Admins manage bracket matches" ON public.tournament_matches;
CREATE POLICY "Admins manage matches" ON public.tournament_matches FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.tournament_touch_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_tournaments_updated ON public.tournaments;
CREATE TRIGGER trg_tournaments_updated BEFORE UPDATE ON public.tournaments
  FOR EACH ROW EXECUTE FUNCTION public.tournament_touch_updated_at();

DROP TRIGGER IF EXISTS trg_tournament_matches_updated ON public.tournament_matches;
CREATE TRIGGER trg_tournament_matches_updated BEFORE UPDATE ON public.tournament_matches
  FOR EACH ROW EXECUTE FUNCTION public.tournament_touch_updated_at();

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
  fill_slot text;
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

  UPDATE public.tournament_participants
    SET is_eliminated = true,
        eliminated_at_round = m.round
    WHERE id = loser_pid;

  next_round := CASE m.round
    WHEN 'opening' THEN 'r16'
    WHEN 'r16' THEN 'qf'
    WHEN 'qf' THEN 'sf'
    WHEN 'sf' THEN 'final'
    ELSE NULL END;

  IF next_round IS NULL THEN
    UPDATE public.tournaments SET champion_participant_id = _winner_id, status = 'completed'
      WHERE id = m.tournament_id;
    RETURN jsonb_build_object('ok', true, 'champion', _winner_id);
  END IF;

  IF m.round = 'opening' THEN
    next_slot := m.slot_index;
    fill_slot := 'a';
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
  RETURN public.tournament_set_result(_match_id, winner_pid, _kills_a, _kills_b);
END $$;

GRANT EXECUTE ON FUNCTION public.tournament_generate_bracket(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tournament_set_result(uuid, uuid, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tournament_disqualify(uuid, uuid, int, int) TO authenticated;

DROP POLICY IF EXISTS "event_banners_read" ON storage.objects;
DROP POLICY IF EXISTS "event_banners_admin_write" ON storage.objects;
CREATE POLICY "event_banners_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'event-banners');
CREATE POLICY "event_banners_admin_write" ON storage.objects FOR ALL
  USING (bucket_id = 'event-banners' AND public.is_admin(auth.uid()))
  WITH CHECK (bucket_id = 'event-banners' AND public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "bracket_emblems_read" ON storage.objects;
DROP POLICY IF EXISTS "bracket_emblems_admin_write" ON storage.objects;
CREATE POLICY "bracket_emblems_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'bracket-emblems');
CREATE POLICY "bracket_emblems_admin_write" ON storage.objects FOR ALL
  USING (bucket_id = 'bracket-emblems' AND public.is_admin(auth.uid()))
  WITH CHECK (bucket_id = 'bracket-emblems' AND public.is_admin(auth.uid()));