-- Roles
CREATE TYPE public.app_role AS ENUM ('admin', 'member');
CREATE TYPE public.match_status AS ENUM ('open', 'live', 'closed', 'resolved', 'cancelled');
CREATE TYPE public.bet_status AS ENUM ('pending', 'won', 'lost', 'refunded');

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT UNIQUE NOT NULL,
  avatar_url TEXT,
  coins BIGINT NOT NULL DEFAULT 1000,
  total_won BIGINT NOT NULL DEFAULT 0,
  total_wagered BIGINT NOT NULL DEFAULT 0,
  bets_won INT NOT NULL DEFAULT 0,
  bets_lost INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role app_role NOT NULL,
  UNIQUE (user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE TABLE public.gangs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT UNIQUE NOT NULL, tag TEXT NOT NULL, description TEXT,
  color TEXT NOT NULL DEFAULT '#ef4444', logo_url TEXT,
  wins INT NOT NULL DEFAULT 0, losses INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.gangs ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL, description TEXT,
  gang_a_id UUID NOT NULL REFERENCES public.gangs(id),
  gang_b_id UUID NOT NULL REFERENCES public.gangs(id),
  status match_status NOT NULL DEFAULT 'open',
  winner_gang_id UUID REFERENCES public.gangs(id),
  scheduled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ,
  pool_a BIGINT NOT NULL DEFAULT 0, pool_b BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (gang_a_id <> gang_b_id)
);
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.bets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  gang_id UUID NOT NULL REFERENCES public.gangs(id),
  amount BIGINT NOT NULL CHECK (amount > 0),
  status bet_status NOT NULL DEFAULT 'pending',
  payout BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.bets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles readable by all" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "users update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);

-- Now drop and rebuild with the real schema
DROP TABLE IF EXISTS public.bets CASCADE;
DROP TABLE IF EXISTS public.matches CASCADE;
DROP TABLE IF EXISTS public.gangs CASCADE;
DROP TABLE IF EXISTS public.user_roles CASCADE;
DROP TABLE IF EXISTS public.profiles CASCADE;
DROP FUNCTION IF EXISTS public.has_role(uuid, public.app_role) CASCADE;
DROP TYPE IF EXISTS public.app_role CASCADE;
DROP TYPE IF EXISTS public.match_status CASCADE;
DROP TYPE IF EXISTS public.bet_status CASCADE;

CREATE TYPE public.app_role AS ENUM ('viewer','shooter','gang_leader','registered','moderator','admin');
CREATE TYPE public.gang_type AS ENUM ('G','F');
CREATE TYPE public.match_status AS ENUM ('scheduled','live','ended','cancelled');
CREATE TYPE public.bet_status AS ENUM ('open','won','lost','cashed_out','void');
CREATE TYPE public.chat_room AS ENUM ('general','gang','moderator');
CREATE TYPE public.ticket_status AS ENUM ('open','pending','resolved','closed');
CREATE TYPE public.token_request_status AS ENUM ('pending','approved','denied');

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL, email TEXT NOT NULL, phone TEXT, discord_username TEXT,
  country TEXT, server TEXT DEFAULT 'LOMITA AFR', gang_name TEXT, gang_type public.gang_type,
  avatar_url TEXT, token_balance BIGINT NOT NULL DEFAULT 0,
  is_banned BOOLEAN NOT NULL DEFAULT false, ban_reason TEXT,
  is_muted BOOLEAN NOT NULL DEFAULT false, mute_reason TEXT,
  is_restricted BOOLEAN NOT NULL DEFAULT false, restrict_reason TEXT,
  accepted_terms BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  assigned_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role public.app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;
CREATE OR REPLACE FUNCTION public.is_admin(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = 'admin')
$$;
CREATE OR REPLACE FUNCTION public.is_mod_or_admin(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role IN ('moderator','admin'))
$$;
CREATE OR REPLACE FUNCTION public.can_use_gang_chat(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role IN ('gang_leader','moderator','admin'))
$$;

CREATE POLICY "profiles readable by all authed" ON public.profiles FOR SELECT TO authenticated USING (true);
CREATE POLICY "users update own profile" ON public.profiles FOR UPDATE TO authenticated USING (auth.uid() = id);
CREATE POLICY "admins update any profile" ON public.profiles FOR UPDATE TO authenticated USING (public.is_admin(auth.uid()));
CREATE POLICY "roles readable by all authed" ON public.user_roles FOR SELECT TO authenticated USING (true);
CREATE POLICY "admins manage roles" ON public.user_roles FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.categories (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), name TEXT NOT NULL UNIQUE, icon TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "categories public read" ON public.categories FOR SELECT USING (true);
CREATE POLICY "admins manage categories" ON public.categories FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.teams (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), name TEXT NOT NULL, logo_url TEXT, gang_type public.gang_type, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;
CREATE POLICY "teams public read" ON public.teams FOR SELECT USING (true);
CREATE POLICY "admins manage teams" ON public.teams FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.players (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), team_id UUID NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE, name TEXT NOT NULL, avatar_url TEXT, is_substitute BOOLEAN NOT NULL DEFAULT false, position TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.players ENABLE ROW LEVEL SECURITY;
CREATE POLICY "players public read" ON public.players FOR SELECT USING (true);
CREATE POLICY "admins manage players" ON public.players FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), name TEXT NOT NULL,
  category_id UUID REFERENCES public.categories(id),
  home_team_id UUID NOT NULL REFERENCES public.teams(id),
  away_team_id UUID NOT NULL REFERENCES public.teams(id),
  location TEXT, start_time TIMESTAMPTZ NOT NULL,
  status public.match_status NOT NULL DEFAULT 'scheduled',
  home_score INT NOT NULL DEFAULT 0, away_score INT NOT NULL DEFAULT 0,
  winner_team_id UUID REFERENCES public.teams(id),
  is_featured BOOLEAN NOT NULL DEFAULT false,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "matches public read" ON public.matches FOR SELECT USING (true);
CREATE POLICY "admins manage matches" ON public.matches FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.markets (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE, name TEXT NOT NULL, is_open BOOLEAN NOT NULL DEFAULT true, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.markets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "markets public read" ON public.markets FOR SELECT USING (true);
CREATE POLICY "admins manage markets" ON public.markets FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.odds (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), market_id UUID NOT NULL REFERENCES public.markets(id) ON DELETE CASCADE, label TEXT NOT NULL, value NUMERIC(8,2) NOT NULL, is_winner BOOLEAN, updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.odds ENABLE ROW LEVEL SECURITY;
CREATE POLICY "odds public read" ON public.odds FOR SELECT USING (true);
CREATE POLICY "admins manage odds" ON public.odds FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.bets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tracking_id TEXT NOT NULL UNIQUE DEFAULT ('LSL-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
  booking_code TEXT NOT NULL UNIQUE DEFAULT upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  stake BIGINT NOT NULL CHECK (stake > 0),
  total_odds NUMERIC(10,2) NOT NULL,
  potential_payout BIGINT NOT NULL,
  status public.bet_status NOT NULL DEFAULT 'open',
  cashout_amount BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  settled_at TIMESTAMPTZ,
  cashed_out_at TIMESTAMPTZ
);
ALTER TABLE public.bets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own bets" ON public.bets FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
CREATE POLICY "users insert own bets" ON public.bets FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users update own open bets" ON public.bets FOR UPDATE TO authenticated USING (auth.uid() = user_id AND status = 'open');
CREATE POLICY "admins manage bets" ON public.bets FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.bet_selections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bet_id UUID NOT NULL REFERENCES public.bets(id) ON DELETE CASCADE,
  match_id UUID REFERENCES public.matches(id) ON DELETE SET NULL,
  market_id UUID NOT NULL REFERENCES public.markets(id),
  odd_id UUID NOT NULL REFERENCES public.odds(id),
  locked_odds NUMERIC(8,2) NOT NULL,
  selection_label TEXT NOT NULL,
  result TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(bet_id, match_id)
);
ALTER TABLE public.bet_selections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "selections via bet ownership" ON public.bet_selections FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.bets b WHERE b.id = bet_id AND (b.user_id = auth.uid() OR public.is_admin(auth.uid()))));
CREATE POLICY "users insert selections" ON public.bet_selections FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM public.bets b WHERE b.id = bet_id AND b.user_id = auth.uid()));
CREATE POLICY "admins manage selections" ON public.bet_selections FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.chat_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  room public.chat_room NOT NULL,
  content TEXT, image_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "chat readable" ON public.chat_messages FOR SELECT TO authenticated USING (
  room = 'general' OR (room = 'gang' AND public.can_use_gang_chat(auth.uid())) OR (room = 'moderator' AND public.is_mod_or_admin(auth.uid()))
);
CREATE POLICY "users post if not muted" ON public.chat_messages FOR INSERT TO authenticated WITH CHECK (
  auth.uid() = user_id
  AND NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND (p.is_muted OR p.is_banned))
  AND (room = 'general' OR (room = 'gang' AND public.can_use_gang_chat(auth.uid())) OR (room = 'moderator' AND public.is_mod_or_admin(auth.uid())))
);
CREATE POLICY "mods delete chat" ON public.chat_messages FOR DELETE TO authenticated USING (public.is_mod_or_admin(auth.uid()));

CREATE TABLE public.announcements (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), title TEXT NOT NULL, body TEXT, image_url TEXT, is_active BOOLEAN NOT NULL DEFAULT true, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "announcements public read" ON public.announcements FOR SELECT USING (true);
CREATE POLICY "admins manage announcements" ON public.announcements FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.highlights (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), title TEXT NOT NULL, media_url TEXT NOT NULL, media_type TEXT NOT NULL DEFAULT 'image', is_active BOOLEAN NOT NULL DEFAULT true, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.highlights ENABLE ROW LEVEL SECURITY;
CREATE POLICY "highlights public read" ON public.highlights FOR SELECT USING (true);
CREATE POLICY "admins manage highlights" ON public.highlights FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.advertisements (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), title TEXT NOT NULL, image_url TEXT, link_url TEXT, is_active BOOLEAN NOT NULL DEFAULT true, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.advertisements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ads public read" ON public.advertisements FOR SELECT USING (true);
CREATE POLICY "admins manage ads" ON public.advertisements FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL, body TEXT, link TEXT,
  is_read BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own notifications" ON public.notifications FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users update own notifications" ON public.notifications FOR UPDATE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "admins manage notifications" ON public.notifications FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.promo_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE, amount BIGINT NOT NULL,
  usage_limit INT NOT NULL DEFAULT 1, used_count INT NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ, is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  max_uses integer,
  target_user_ids uuid[]
);
ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins manage promos" ON public.promo_codes FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));
CREATE POLICY "promos read by targeted user" ON public.promo_codes FOR SELECT TO authenticated USING (
  public.is_admin(auth.uid()) OR (target_user_ids IS NOT NULL AND auth.uid() = ANY(target_user_ids))
);

CREATE TABLE public.promo_redemptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  promo_id UUID NOT NULL REFERENCES public.promo_codes(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount BIGINT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(promo_id, user_id)
);
ALTER TABLE public.promo_redemptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own redemptions" ON public.promo_redemptions FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

CREATE TABLE public.support_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  subject TEXT NOT NULL,
  status public.ticket_status NOT NULL DEFAULT 'open',
  assigned_to UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own tickets" ON public.support_tickets FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.is_mod_or_admin(auth.uid()));
CREATE POLICY "users create tickets" ON public.support_tickets FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "mods update tickets" ON public.support_tickets FOR UPDATE TO authenticated USING (public.is_mod_or_admin(auth.uid()) OR auth.uid() = user_id);
CREATE POLICY "mods delete tickets" ON public.support_tickets FOR DELETE TO authenticated USING (public.is_mod_or_admin(auth.uid()));

CREATE TABLE public.ticket_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id),
  content TEXT, image_url TEXT,
  is_ai BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.ticket_messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ticket msgs via ownership" ON public.ticket_messages FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.id = ticket_id AND (t.user_id = auth.uid() OR public.is_mod_or_admin(auth.uid()))));
CREATE POLICY "ticket msgs insert" ON public.ticket_messages FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.id = ticket_id AND (t.user_id = auth.uid() OR public.is_mod_or_admin(auth.uid()))));
CREATE POLICY "mods delete ticket messages" ON public.ticket_messages FOR DELETE TO authenticated USING (public.is_mod_or_admin(auth.uid()));

CREATE TABLE public.token_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount BIGINT NOT NULL CHECK (amount > 0),
  proof_image_url TEXT, note TEXT,
  status public.token_request_status NOT NULL DEFAULT 'pending',
  reviewed_by UUID REFERENCES auth.users(id), review_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(), reviewed_at TIMESTAMPTZ
);
ALTER TABLE public.token_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own requests" ON public.token_requests FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
CREATE POLICY "users create requests" ON public.token_requests FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "admins update requests" ON public.token_requests FOR UPDATE TO authenticated USING (public.is_admin(auth.uid()));

CREATE TABLE public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id UUID REFERENCES auth.users(id),
  action TEXT NOT NULL, target_type TEXT, target_id TEXT,
  metadata JSONB, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins read logs" ON public.audit_logs FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

CREATE TABLE public.app_settings (
  id INT PRIMARY KEY DEFAULT 1,
  maintenance_mode BOOLEAN NOT NULL DEFAULT false,
  maintenance_message TEXT DEFAULT 'We are currently performing maintenance. Please check back soon.',
  terms_content TEXT DEFAULT '',
  contact_email TEXT DEFAULT 'lomitashootersleague@gmail.com',
  contact_phone TEXT, contact_whatsapp TEXT,
  about_us TEXT, why_trust_us TEXT,
  hero_tagline TEXT DEFAULT 'Season 4 · Live',
  popup_ad_active BOOLEAN NOT NULL DEFAULT false,
  popup_ad_image TEXT, popup_ad_text TEXT, popup_ad_link TEXT,
  popup_ad_size TEXT NOT NULL DEFAULT 'large',
  min_stake BIGINT NOT NULL DEFAULT 2000000,
  max_payout bigint NOT NULL DEFAULT 100000000,
  min_withdrawal bigint NOT NULL DEFAULT 2000000,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  vapid_public_key text, vapid_subject text, push_endpoint_url text,
  daily_login_enabled boolean NOT NULL DEFAULT true,
  daily_login_base_reward bigint NOT NULL DEFAULT 100000,
  daily_login_bonus_per_day numeric NOT NULL DEFAULT 0.1,
  daily_login_max_streak integer NOT NULL DEFAULT 30,
  xp_per_bet integer NOT NULL DEFAULT 10,
  xp_per_win integer NOT NULL DEFAULT 25,
  xp_per_login integer NOT NULL DEFAULT 5,
  xp_per_referral integer NOT NULL DEFAULT 100,
  referral_bonus_referrer bigint NOT NULL DEFAULT 500000,
  referral_bonus_referee bigint NOT NULL DEFAULT 250000,
  vip_token_multipliers jsonb NOT NULL DEFAULT '{"bronze":1,"silver":1.05,"gold":1.10,"platinum":1.25,"legend":1.50}'::jsonb,
  challenge_reward_multiplier numeric NOT NULL DEFAULT 1,
  spin_enabled boolean NOT NULL DEFAULT false,
  spin_min_reward bigint NOT NULL DEFAULT 10000,
  spin_max_reward bigint NOT NULL DEFAULT 500000,
  spin_cooldown_hours integer NOT NULL DEFAULT 24,
  gift_enabled boolean NOT NULL DEFAULT false,
  gift_daily_limit integer NOT NULL DEFAULT 5,
  gift_min_amount bigint NOT NULL DEFAULT 100000,
  gift_max_per_tx bigint NOT NULL DEFAULT 5000000,
  gift_fee_pct numeric NOT NULL DEFAULT 0,
  friends_enabled boolean NOT NULL DEFAULT true,
  admin_ai_enabled boolean NOT NULL DEFAULT true,
  admin_ai_model text NOT NULL DEFAULT 'google/gemini-2.5-flash',
  exposure_warn_pct integer NOT NULL DEFAULT 70,
  house_low_balance bigint NOT NULL DEFAULT 1000000,
  min_selections_per_ticket integer NOT NULL DEFAULT 1,
  max_selections_per_ticket integer NOT NULL DEFAULT 20,
  emblem_auto_approve boolean NOT NULL DEFAULT false,
  vip_enabled boolean NOT NULL DEFAULT true,
  CONSTRAINT singleton CHECK (id = 1)
);
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "settings public read" ON public.app_settings FOR SELECT USING (true);
CREATE POLICY "admins update settings" ON public.app_settings FOR UPDATE TO authenticated USING (public.is_admin(auth.uid()));
CREATE POLICY "admins insert settings" ON public.app_settings FOR INSERT TO authenticated WITH CHECK (public.is_admin(auth.uid()));
INSERT INTO public.app_settings (id) VALUES (1);

CREATE TABLE public.token_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  amount bigint NOT NULL,
  balance_after bigint NOT NULL,
  kind text NOT NULL, description text, metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_tx_user ON public.token_transactions(user_id, created_at DESC);
ALTER TABLE public.token_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own tx" ON public.token_transactions FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.log_token_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE diff bigint;
BEGIN
  diff := COALESCE(NEW.token_balance,0) - COALESCE(OLD.token_balance,0);
  IF diff <> 0 THEN
    INSERT INTO public.token_transactions(user_id, amount, balance_after, kind, description)
    VALUES (NEW.id, diff, NEW.token_balance, 'balance_change', CASE WHEN diff > 0 THEN 'Credit' ELSE 'Debit' END);
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;
CREATE TRIGGER t_profiles_updated BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE TRIGGER t_matches_updated BEFORE UPDATE ON public.matches FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE TRIGGER t_tickets_updated BEFORE UPDATE ON public.support_tickets FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

INSERT INTO storage.buckets (id, name, public) VALUES
  ('avatars','avatars',true),('chat-images','chat-images',true),('team-logos','team-logos',true),
  ('player-avatars','player-avatars',true),('announcements','announcements',true),
  ('highlights','highlights',true),('ads','ads',true),
  ('ticket-uploads','ticket-uploads',false),('token-proofs','token-proofs',false),
  ('gang-emblems','gang-emblems',true),('profile-banners','profile-banners',true),
  ('event-banners','event-banners',true),('season-banners','season-banners',true),
  ('popup-ads','popup-ads',true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "public read public buckets" ON storage.objects FOR SELECT USING (
  bucket_id IN ('avatars','chat-images','team-logos','player-avatars','announcements','highlights','ads','gang-emblems','profile-banners','event-banners','season-banners','popup-ads')
);
CREATE POLICY "users upload own private files" ON storage.objects FOR INSERT TO authenticated WITH CHECK (
  bucket_id IN ('ticket-uploads','token-proofs','avatars') AND (auth.uid())::text = (storage.foldername(name))[1]
);
CREATE POLICY "users read own private files" ON storage.objects FOR SELECT TO authenticated USING (
  bucket_id IN ('ticket-uploads','token-proofs') AND ((auth.uid())::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid()))
);
CREATE POLICY "users delete own files" ON storage.objects FOR DELETE TO authenticated USING (
  (auth.uid())::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid())
);
CREATE POLICY "users update own files" ON storage.objects FOR UPDATE TO authenticated USING (
  (auth.uid())::text = (storage.foldername(name))[1]
);
CREATE POLICY "admins write public asset buckets" ON storage.objects FOR INSERT TO authenticated WITH CHECK (
  bucket_id = any (array['ads','announcements','highlights','team-logos','player-avatars','gang-emblems','event-banners','season-banners','popup-ads','chat-images']::text[])
  AND public.is_mod_or_admin(auth.uid())
);

CREATE TABLE public.events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL, description text, banner_url text,
  starts_at timestamptz, ends_at timestamptz NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "events readable" ON public.events FOR SELECT USING (true);
CREATE POLICY "events admin write" ON public.events FOR ALL USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.ban_appeals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  message text NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  admin_response text,
  created_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz
);
ALTER TABLE public.ban_appeals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "appeals own select" ON public.ban_appeals FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
CREATE POLICY "appeals own insert" ON public.ban_appeals FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "appeals admin update" ON public.ban_appeals FOR UPDATE USING (public.is_admin(auth.uid()));

CREATE TYPE public.withdrawal_status AS ENUM ('pending','approved','declined');

CREATE TABLE public.withdrawal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  ingame_name text NOT NULL, gang_name text NOT NULL,
  amount bigint NOT NULL CHECK (amount > 0),
  ticket_ref text,
  status public.withdrawal_status NOT NULL DEFAULT 'pending',
  admin_note text, reviewed_by uuid, reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.withdrawal_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users insert own withdrawals" ON public.withdrawal_requests FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users view own withdrawals" ON public.withdrawal_requests FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
CREATE POLICY "admins update withdrawals" ON public.withdrawal_requests FOR UPDATE TO authenticated USING (public.is_admin(auth.uid()));
CREATE POLICY "admins delete withdrawals" ON public.withdrawal_requests FOR DELETE TO authenticated USING (public.is_admin(auth.uid()));

CREATE TABLE public.leaderboard_overrides (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('gang','shooter')),
  name text NOT NULL, top_player text,
  wins int NOT NULL DEFAULT 0, losses int NOT NULL DEFAULT 0,
  draws int NOT NULL DEFAULT 0, played int NOT NULL DEFAULT 0,
  points int NOT NULL DEFAULT 0, manual_rank int,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.leaderboard_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leaderboard public read" ON public.leaderboard_overrides FOR SELECT USING (true);
CREATE POLICY "leaderboard admin write" ON public.leaderboard_overrides FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'sponsor';
ALTER TYPE public.bet_status ADD VALUE IF NOT EXISTS 'suspended';
ALTER TYPE public.bet_status ADD VALUE IF NOT EXISTS 'refunded';
