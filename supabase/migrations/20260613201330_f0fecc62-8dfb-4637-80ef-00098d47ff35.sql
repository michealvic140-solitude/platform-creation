-- Drop functions whose return types changed
DROP FUNCTION IF EXISTS public.admin_refund_bet(uuid, text);
DROP FUNCTION IF EXISTS public.admin_void_bet(uuid, boolean, text);

DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
           WHERE n.nspname='public' AND c.relkind='r'
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t.relname);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t.relname);
  END LOOP;
END $$;

GRANT SELECT ON public.advertisements TO anon;
GRANT SELECT ON public.announcements TO anon;
GRANT SELECT ON public.app_settings TO anon;
GRANT SELECT ON public.ban_appeals TO anon;
GRANT SELECT ON public.categories TO anon;
GRANT SELECT ON public.events TO anon;
GRANT SELECT ON public.highlights TO anon;
GRANT SELECT ON public.leaderboard_overrides TO anon;
GRANT SELECT ON public.markets TO anon;
GRANT SELECT ON public.matches TO anon;
GRANT SELECT ON public.odds TO anon;
GRANT SELECT ON public.players TO anon;
GRANT SELECT ON public.season_points TO anon;
GRANT SELECT ON public.seasons TO anon;
GRANT SELECT ON public.spotlights TO anon;
GRANT SELECT ON public.teams TO anon;
GRANT SELECT ON public.token_transactions TO anon;

ALTER TABLE public.players ALTER COLUMN team_id DROP NOT NULL;

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS match_kind text NOT NULL DEFAULT 'gang',
  ADD COLUMN IF NOT EXISTS home_player_id uuid REFERENCES public.players(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS away_player_id uuid REFERENCES public.players(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS marketing_enabled boolean NOT NULL DEFAULT false;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='matches_match_kind_check') THEN
    ALTER TABLE public.matches ADD CONSTRAINT matches_match_kind_check CHECK (match_kind IN ('gang','shooter','future'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_matches_match_kind ON public.matches(match_kind);
CREATE INDEX IF NOT EXISTS idx_matches_home_player_id ON public.matches(home_player_id);
CREATE INDEX IF NOT EXISTS idx_matches_away_player_id ON public.matches(away_player_id);

ALTER TABLE public.odds
  ADD COLUMN IF NOT EXISTS future_candidate_type text,
  ADD COLUMN IF NOT EXISTS future_emblem_url text,
  ADD COLUMN IF NOT EXISTS future_status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS future_next_title text,
  ADD COLUMN IF NOT EXISTS future_next_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS future_progress jsonb NOT NULL DEFAULT '[]'::jsonb;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='odds_future_status_check') THEN
    ALTER TABLE public.odds ADD CONSTRAINT odds_future_status_check CHECK (future_status IN ('active','qualified','disqualified','lost','winner','settled'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_odds_future_status ON public.odds(future_status);

ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS futures_section_title text NOT NULL DEFAULT 'SEASONAL TOURNAMENT',
  ADD COLUMN IF NOT EXISTS futures_min_stake bigint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS futures_max_payout bigint NOT NULL DEFAULT 100000000,
  ADD COLUMN IF NOT EXISTS futures_max_selections integer NOT NULL DEFAULT 1;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='app_settings_futures_max_selections_check') THEN
    ALTER TABLE public.app_settings ADD CONSTRAINT app_settings_futures_max_selections_check CHECK (futures_max_selections BETWEEN 1 AND 3);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.tournaments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  tagline text DEFAULT 'ONE LEAGUE. NO MERCY. RESPECT THE GAME.',
  event_date date,
  status text NOT NULL DEFAULT 'draft',
  is_featured boolean NOT NULL DEFAULT false,
  champion_id uuid,
  futures_match_id uuid REFERENCES public.matches(id) ON DELETE SET NULL,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.tournaments TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournaments TO authenticated;
GRANT ALL ON public.tournaments TO service_role;
ALTER TABLE public.tournaments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Tournaments are viewable by everyone" ON public.tournaments;
CREATE POLICY "Tournaments are viewable by everyone" ON public.tournaments FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage tournaments" ON public.tournaments;
CREATE POLICY "Admins manage tournaments" ON public.tournaments FOR ALL TO authenticated
  USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.tournament_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  name text NOT NULL,
  logo_url text,
  seed int,
  current_round int NOT NULL DEFAULT 1,
  is_eliminated boolean NOT NULL DEFAULT false,
  eliminated_round int,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.tournament_participants TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournament_participants TO authenticated;
GRANT ALL ON public.tournament_participants TO service_role;
ALTER TABLE public.tournament_participants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Participants viewable by everyone" ON public.tournament_participants;
CREATE POLICY "Participants viewable by everyone" ON public.tournament_participants FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage participants" ON public.tournament_participants;
CREATE POLICY "Admins manage participants" ON public.tournament_participants FOR ALL TO authenticated
  USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='tournaments_champion_fk') THEN
    ALTER TABLE public.tournaments ADD CONSTRAINT tournaments_champion_fk FOREIGN KEY (champion_id) REFERENCES public.tournament_participants(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.tournament_matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  round int NOT NULL,
  round_name text,
  slot int NOT NULL DEFAULT 0,
  label text,
  participant_a_id uuid REFERENCES public.tournament_participants(id) ON DELETE SET NULL,
  participant_b_id uuid REFERENCES public.tournament_participants(id) ON DELETE SET NULL,
  score_a int,
  score_b int,
  winner_id uuid REFERENCES public.tournament_participants(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending',
  next_match_id uuid REFERENCES public.tournament_matches(id) ON DELETE SET NULL,
  next_slot text,
  scheduled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.tournament_matches TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tournament_matches TO authenticated;
GRANT ALL ON public.tournament_matches TO service_role;
ALTER TABLE public.tournament_matches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Bracket matches viewable by everyone" ON public.tournament_matches;
CREATE POLICY "Bracket matches viewable by everyone" ON public.tournament_matches FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage bracket matches" ON public.tournament_matches;
CREATE POLICY "Admins manage bracket matches" ON public.tournament_matches FOR ALL TO authenticated
  USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE INDEX IF NOT EXISTS idx_tmatch_tournament ON public.tournament_matches(tournament_id);
CREATE INDEX IF NOT EXISTS idx_tpart_tournament ON public.tournament_participants(tournament_id);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_tournaments_updated') THEN
    CREATE TRIGGER trg_tournaments_updated BEFORE UPDATE ON public.tournaments
      FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_tmatches_updated') THEN
    CREATE TRIGGER trg_tmatches_updated BEFORE UPDATE ON public.tournament_matches
      FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.set_tournament_result(_match_id uuid, _score_a int, _score_b int, _winner_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m record; loser uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO m FROM public.tournament_matches WHERE id = _match_id FOR UPDATE;
  IF m IS NULL THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF _winner_id IS NOT NULL AND _winner_id <> m.participant_a_id AND _winner_id <> m.participant_b_id THEN
    RAISE EXCEPTION 'Winner must be one of the two participants';
  END IF;
  UPDATE public.tournament_matches
    SET score_a=_score_a, score_b=_score_b, winner_id=_winner_id,
        status = CASE WHEN _winner_id IS NOT NULL THEN 'completed' ELSE 'live' END,
        updated_at = now()
    WHERE id = _match_id;
  IF _winner_id IS NOT NULL THEN
    loser := CASE WHEN _winner_id = m.participant_a_id THEN m.participant_b_id ELSE m.participant_a_id END;
    IF loser IS NOT NULL THEN
      UPDATE public.tournament_participants SET is_eliminated=true, eliminated_round=m.round WHERE id=loser;
    END IF;
    UPDATE public.tournament_participants SET current_round=m.round+1, is_eliminated=false WHERE id=_winner_id;
    IF m.next_match_id IS NOT NULL THEN
      IF m.next_slot = 'a' THEN
        UPDATE public.tournament_matches SET participant_a_id=_winner_id, updated_at=now() WHERE id=m.next_match_id;
      ELSE
        UPDATE public.tournament_matches SET participant_b_id=_winner_id, updated_at=now() WHERE id=m.next_match_id;
      END IF;
    ELSE
      UPDATE public.tournaments SET champion_id=_winner_id, status='completed', updated_at=now() WHERE id=m.tournament_id;
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

DO $$ BEGIN
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.tournaments; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.tournament_participants; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.tournament_matches; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;

CREATE OR REPLACE FUNCTION public.protect_profile_sensitive_fields()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.role() = 'service_role' OR public.is_admin(auth.uid()) THEN RETURN NEW; END IF;
  NEW.token_balance := OLD.token_balance;
  NEW.is_banned := OLD.is_banned;
  NEW.ban_reason := OLD.ban_reason;
  NEW.is_muted := OLD.is_muted;
  NEW.mute_reason := OLD.mute_reason;
  NEW.is_restricted := OLD.is_restricted;
  NEW.restrict_reason := OLD.restrict_reason;
  NEW.vip_tier := OLD.vip_tier;
  NEW.xp := OLD.xp;
  NEW.streak_days := OLD.streak_days;
  NEW.longest_streak := OLD.longest_streak;
  NEW.last_login_date := OLD.last_login_date;
  NEW.referral_code := OLD.referral_code;
  NEW.referred_by := OLD.referred_by;
  NEW.emblem_status := OLD.emblem_status;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_void_bet(_bet_id uuid, _refund boolean DEFAULT false, _reason text DEFAULT NULL::text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE b record;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO b FROM public.bets WHERE id=_bet_id FOR UPDATE;
  IF b IS NULL THEN RAISE EXCEPTION 'Bet not found'; END IF;
  IF b.status IN ('void','refunded') THEN RAISE EXCEPTION 'Ticket already % — cannot void again', b.status; END IF;
  IF _refund AND b.status IN ('won','cashed_out') THEN
    RAISE EXCEPTION 'Stake already settled — cannot refund again (status: %)', b.status;
  END IF;
  IF _refund THEN
    UPDATE public.profiles SET token_balance = token_balance + b.stake WHERE id = b.user_id;
  END IF;
  UPDATE public.bets SET status='void', settled_at = COALESCE(settled_at, now()) WHERE id=_bet_id;
  INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (b.user_id, 'Ticket voided', COALESCE(_reason,'Your bet ticket has been voided by an admin.') || CASE WHEN _refund THEN ' Stake refunded.' ELSE '' END, '/ticket/'||_bet_id);
  INSERT INTO public.audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (auth.uid(), 'void_bet', 'bet', _bet_id::text, jsonb_build_object('reason', _reason, 'refunded', _refund, 'stake', b.stake));
END $function$;
REVOKE ALL ON FUNCTION public.admin_void_bet(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_void_bet(uuid, boolean, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_refund_bet(_bet_id uuid, _reason text DEFAULT NULL::text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE b record;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO b FROM public.bets WHERE id=_bet_id FOR UPDATE;
  IF b IS NULL THEN RAISE EXCEPTION 'Bet not found'; END IF;
  IF b.status IN ('refunded','won','cashed_out') THEN
    RAISE EXCEPTION 'Stake already settled or refunded — cannot refund again (status: %)', b.status;
  END IF;
  UPDATE public.profiles SET token_balance = token_balance + b.stake WHERE id = b.user_id;
  UPDATE public.bets SET status='refunded', settled_at = COALESCE(settled_at, now()) WHERE id=_bet_id;
  INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (b.user_id, 'Ticket refunded', COALESCE(_reason,'Your bet stake has been refunded by an admin.') || ' +' || b.stake || ' tokens.', '/ticket/'||_bet_id);
  INSERT INTO public.audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (auth.uid(), 'refund_bet', 'bet', _bet_id::text, jsonb_build_object('reason', _reason, 'stake', b.stake));
END $function$;
REVOKE ALL ON FUNCTION public.admin_refund_bet(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_refund_bet(uuid, text) TO authenticated;

ALTER TABLE public.leaderboard_overrides ADD COLUMN IF NOT EXISTS total_score integer NOT NULL DEFAULT 0;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS home_present boolean NOT NULL DEFAULT true;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS away_present boolean NOT NULL DEFAULT true;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS restrict_repeat_contender boolean NOT NULL DEFAULT false;

ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS allow_rebet boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.user_cashout_bet(_bet_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  b record;
  total_sels int; won_eval_sels int;
  payout bigint;
  new_bal bigint; new_house bigint; paused boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT payouts_paused INTO paused FROM public.house_wallet WHERE id = 1;
  IF paused THEN RAISE EXCEPTION 'Payouts are temporarily paused by the house. Please try again later.'; END IF;
  SELECT * INTO b FROM public.bets WHERE id = _bet_id FOR UPDATE;
  IF b IS NULL THEN RAISE EXCEPTION 'Ticket not found'; END IF;
  IF b.user_id <> auth.uid() THEN RAISE EXCEPTION 'Not your ticket'; END IF;
  IF b.status <> 'open' THEN RAISE EXCEPTION 'Ticket is %, cannot cash out', b.status; END IF;
  WITH s AS (
    SELECT bs.result, bs.selection_label, o.future_status,
           m.match_kind, m.status AS mstatus, m.home_score, m.away_score,
           ht.name AS home_name, at.name AS away_name, mk.name AS market_name
    FROM public.bet_selections bs
    JOIN public.odds o ON o.id = bs.odd_id
    LEFT JOIN public.matches m ON m.id = bs.match_id
    LEFT JOIN public.teams ht ON ht.id = m.home_team_id
    LEFT JOIN public.teams at ON at.id = m.away_team_id
    LEFT JOIN public.markets mk ON mk.id = bs.market_id
    WHERE bs.bet_id = _bet_id
  ), evaluated AS (
    SELECT
      CASE
        WHEN result = 'won' THEN true
        WHEN result = 'lost' THEN false
        WHEN match_kind = 'future' THEN future_status = 'winner'
        WHEN mstatus <> 'ended' THEN false
        WHEN market_name = 'Correct Score' THEN selection_label = (home_score::text || '-' || away_score::text)
        ELSE selection_label = CASE WHEN home_score > away_score THEN home_name WHEN away_score > home_score THEN away_name ELSE 'Draw' END
      END AS winning
    FROM s
  )
  SELECT count(*), count(*) FILTER (WHERE winning IS TRUE)
  INTO total_sels, won_eval_sels FROM evaluated;
  IF total_sels = 0 THEN RAISE EXCEPTION 'No selections on this ticket'; END IF;
  IF won_eval_sels < total_sels THEN
    RAISE EXCEPTION 'Cash-out locked: every match must have ended and every selection must have won';
  END IF;
  payout := b.potential_payout;
  IF payout < 1 THEN payout := 1; END IF;
  UPDATE public.profiles SET token_balance = token_balance + payout WHERE id = b.user_id RETURNING token_balance INTO new_bal;
  UPDATE public.house_wallet SET balance = balance - payout, total_out = total_out + payout, updated_at = now() WHERE id = 1 RETURNING balance INTO new_house;
  INSERT INTO public.house_transactions(kind, amount, balance_after, user_id, bet_id, reason)
    VALUES ('cashout', -payout, new_house, b.user_id, b.id, 'Cashout of bet ' || b.tracking_id);
  UPDATE public.bets SET status = 'cashed_out', cashout_amount = payout, cashed_out_at = now(), settled_at = COALESCE(settled_at, now()) WHERE id = _bet_id;
  INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (b.user_id, 'Ticket cashed out', '+' || payout || ' tokens credited.', '/ticket/'||_bet_id);
  RETURN jsonb_build_object('credited', payout, 'balance', new_bal, 'full', true);
END $function$;

ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS leaderboard_header_url text;
UPDATE public.app_settings
  SET leaderboard_header_url = '/__l5e/assets-v1/3e785487-fb67-4d21-9956-89ae56dbfab1/leaderboard-header.png'
  WHERE id = 1 AND (leaderboard_header_url IS NULL OR leaderboard_header_url = '');

CREATE OR REPLACE FUNCTION public.enforce_one_open_bet_per_match()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE uid uuid; existing_count int; m_kind text; m_restrict boolean;
BEGIN
  IF NEW.match_id IS NULL THEN RETURN NEW; END IF;
  SELECT user_id INTO uid FROM public.bets WHERE id = NEW.bet_id;
  IF uid IS NULL THEN RETURN NEW; END IF;
  SELECT match_kind, COALESCE(restrict_repeat_contender, false) INTO m_kind, m_restrict
    FROM public.matches WHERE id = NEW.match_id;
  IF m_kind = 'future' THEN
    IF m_restrict THEN
      SELECT COUNT(*) INTO existing_count
      FROM public.bet_selections bs JOIN public.bets b ON b.id = bs.bet_id
      WHERE bs.match_id = NEW.match_id AND bs.odd_id = NEW.odd_id AND b.user_id = uid
        AND b.status IN ('open','suspended') AND bs.bet_id <> NEW.bet_id;
      IF existing_count > 0 THEN
        RAISE EXCEPTION 'You already backed this contender. Pick a different one.';
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  SELECT COUNT(*) INTO existing_count
  FROM public.bet_selections bs JOIN public.bets b ON b.id = bs.bet_id
  WHERE bs.match_id = NEW.match_id AND b.user_id = uid
    AND b.status IN ('open','suspended') AND bs.bet_id <> NEW.bet_id;
  IF existing_count > 0 THEN
    RAISE EXCEPTION 'You already have an active ticket on this match. Each match can only be staked once until it settles.';
  END IF;
  RETURN NEW;
END $function$;

DROP FUNCTION IF EXISTS public.admin_list_users_with_kyc();
CREATE OR REPLACE FUNCTION public.admin_list_users_with_kyc()
 RETURNS TABLE(id uuid, full_name text, email text, phone text, discord_username text, discord_full_name text, avatar_url text, gang_name text, gang_type text, token_balance bigint, is_banned boolean, is_muted boolean, is_restricted boolean, vip_tier text, xp bigint, created_at timestamp with time zone, email_confirmed boolean, total_bets bigint)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT p.id, p.full_name, p.email, p.phone, p.discord_username, p.discord_full_name,
    p.avatar_url, p.gang_name, p.gang_type::text, p.token_balance,
    p.is_banned, p.is_muted, p.is_restricted, p.vip_tier, p.xp, p.created_at,
    (u.email_confirmed_at IS NOT NULL) AS email_confirmed,
    COALESCE((SELECT count(*) FROM public.bets b WHERE b.user_id = p.id), 0)::bigint AS total_bets
  FROM public.profiles p
  LEFT JOIN auth.users u ON u.id = p.id
  WHERE public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'moderator')
  ORDER BY p.created_at DESC LIMIT 1000;
$function$;

ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS closed_mode boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS closed_message text NOT NULL DEFAULT 'The website is currently closed. Please check back later.';
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS hot_bets_reset_at timestamptz,
  ADD COLUMN IF NOT EXISTS maintenance_image text,
  ADD COLUMN IF NOT EXISTS closed_image text;

DROP POLICY IF EXISTS "broadcasts read authed" ON public.broadcasts;
DROP POLICY IF EXISTS "friends read authed" ON public.friends;
DROP POLICY IF EXISTS "friends own read" ON public.friends;
CREATE POLICY "friends own read" ON public.friends
  FOR SELECT TO authenticated
  USING (follower_id = auth.uid() OR followee_id = auth.uid());

DROP POLICY IF EXISTS "profiles readable by all authed" ON public.profiles;
DROP POLICY IF EXISTS "profiles own or admin read" ON public.profiles;
CREATE POLICY "profiles own or admin read" ON public.profiles
  FOR SELECT TO authenticated USING (auth.uid() = id OR is_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.gang_directory()
RETURNS TABLE(name text, type text, members bigint, tokens bigint, sample text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT gang_name, max(gang_type::text), count(*), coalesce(sum(token_balance), 0)::bigint,
         (array_agg(full_name ORDER BY token_balance DESC NULLS LAST))[1:4]
  FROM public.profiles WHERE gang_name IS NOT NULL GROUP BY gang_name
$$;
GRANT EXECUTE ON FUNCTION public.gang_directory() TO anon, authenticated;

DROP POLICY IF EXISTS "roles readable by all authed" ON public.user_roles;
DROP POLICY IF EXISTS "user_roles own or admin read" ON public.user_roles;
CREATE POLICY "user_roles own or admin read" ON public.user_roles
  FOR SELECT TO authenticated USING (user_id = auth.uid() OR is_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.get_display_roles(_user_id uuid)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(array_agg(role::text), '{}'::text[])
  FROM public.user_roles WHERE user_id = _user_id AND role::text IN ('admin','moderator');
$$;
GRANT EXECUTE ON FUNCTION public.get_display_roles(uuid) TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.app_settings_private (
  id integer PRIMARY KEY DEFAULT 1,
  admin_ai_model text NOT NULL DEFAULT 'google/gemini-2.5-flash',
  admin_ai_enabled boolean NOT NULL DEFAULT true,
  exposure_warn_pct integer NOT NULL DEFAULT 70,
  house_low_balance bigint NOT NULL DEFAULT 1000000,
  push_endpoint_url text,
  vapid_subject text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT app_settings_private_singleton CHECK (id = 1)
);

INSERT INTO public.app_settings_private (id, admin_ai_model, admin_ai_enabled, exposure_warn_pct, house_low_balance, push_endpoint_url, vapid_subject)
SELECT 1,
  COALESCE((SELECT admin_ai_model FROM public.app_settings WHERE id=1), 'google/gemini-2.5-flash'),
  COALESCE((SELECT admin_ai_enabled FROM public.app_settings WHERE id=1), true),
  COALESCE((SELECT exposure_warn_pct FROM public.app_settings WHERE id=1), 70),
  COALESCE((SELECT house_low_balance FROM public.app_settings WHERE id=1), 1000000),
  (SELECT push_endpoint_url FROM public.app_settings WHERE id=1),
  (SELECT vapid_subject FROM public.app_settings WHERE id=1)
WHERE NOT EXISTS (SELECT 1 FROM public.app_settings_private WHERE id=1);

GRANT SELECT, INSERT, UPDATE ON public.app_settings_private TO authenticated;
GRANT ALL ON public.app_settings_private TO service_role;
ALTER TABLE public.app_settings_private ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "private settings admin" ON public.app_settings_private;
CREATE POLICY "private settings admin" ON public.app_settings_private
  FOR ALL TO authenticated USING (is_admin(auth.uid())) WITH CHECK (is_admin(auth.uid()));

ALTER TABLE public.app_settings DROP COLUMN IF EXISTS admin_ai_model;
ALTER TABLE public.app_settings DROP COLUMN IF EXISTS admin_ai_enabled;
ALTER TABLE public.app_settings DROP COLUMN IF EXISTS exposure_warn_pct;
ALTER TABLE public.app_settings DROP COLUMN IF EXISTS house_low_balance;
ALTER TABLE public.app_settings DROP COLUMN IF EXISTS push_endpoint_url;
ALTER TABLE public.app_settings DROP COLUMN IF EXISTS vapid_subject;

DROP VIEW IF EXISTS public.public_profiles;
CREATE OR REPLACE FUNCTION public.public_profiles(_ids uuid[] DEFAULT NULL)
RETURNS TABLE(id uuid, full_name text, ingame_name text, gang_name text, gang_type text, vip_tier text, xp bigint, streak_days integer, longest_streak integer, profile_title text, avatar_url text, country text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id, full_name, ingame_name, gang_name, gang_type::text, vip_tier, xp,
         streak_days, longest_streak, profile_title, avatar_url, country
  FROM public.profiles
  WHERE _ids IS NULL OR id = ANY(_ids)
  ORDER BY full_name
$$;
GRANT EXECUTE ON FUNCTION public.public_profiles(uuid[]) TO anon, authenticated;