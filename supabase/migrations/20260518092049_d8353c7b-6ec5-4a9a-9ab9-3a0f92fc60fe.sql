
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS ingame_name text,
  ADD COLUMN IF NOT EXISTS discord_full_name text,
  ADD COLUMN IF NOT EXISTS streak_days integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS longest_streak integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_login_date date,
  ADD COLUMN IF NOT EXISTS referral_code text UNIQUE,
  ADD COLUMN IF NOT EXISTS referred_by uuid,
  ADD COLUMN IF NOT EXISTS xp bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS vip_tier text NOT NULL DEFAULT 'bronze',
  ADD COLUMN IF NOT EXISTS gang_emblem_url text,
  ADD COLUMN IF NOT EXISTS emblem_status text,
  ADD COLUMN IF NOT EXISTS chat_color text,
  ADD COLUMN IF NOT EXISTS profile_banner_url text,
  ADD COLUMN IF NOT EXISTS profile_title text,
  ADD COLUMN IF NOT EXISTS showcase_achievement_ids uuid[] NOT NULL DEFAULT '{}'::uuid[];

ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false;

-- Signup trigger
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email, phone, discord_username, discord_full_name, ingame_name, country, server, gang_name, gang_type)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email,'@',1)),
    NEW.email,
    NEW.raw_user_meta_data->>'phone',
    NEW.raw_user_meta_data->>'discord_username',
    NEW.raw_user_meta_data->>'discord_full_name',
    NEW.raw_user_meta_data->>'ingame_name',
    NEW.raw_user_meta_data->>'country',
    COALESCE(NEW.raw_user_meta_data->>'server','LOMITA AFR'),
    NEW.raw_user_meta_data->>'gang_name',
    NULLIF(NEW.raw_user_meta_data->>'gang_type','')::public.gang_type
  );
  IF NEW.email = 'lomitashootersleague@gmail.com' THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'admin');
  ELSE
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'viewer');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Backfill referral codes
UPDATE public.profiles SET referral_code = 'LSL-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)) WHERE referral_code IS NULL;
CREATE OR REPLACE FUNCTION public.gen_referral_code() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.referral_code IS NULL THEN
    NEW.referral_code := 'LSL-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_gen_referral_code ON public.profiles;
CREATE TRIGGER trg_gen_referral_code BEFORE INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.gen_referral_code();

-- Tasks & achievements
CREATE TABLE IF NOT EXISTS public.user_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  title text NOT NULL, description text,
  reward_tokens bigint NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'pending',
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_tasks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own tasks" ON public.user_tasks FOR SELECT TO authenticated USING (auth.uid()=user_id OR public.is_admin(auth.uid()));
CREATE POLICY "admins manage tasks" ON public.user_tasks FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.user_achievements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  code text NOT NULL, title text NOT NULL, description text, icon text,
  awarded_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users see own achievements" ON public.user_achievements FOR SELECT TO authenticated USING (auth.uid()=user_id OR public.is_admin(auth.uid()));
CREATE POLICY "admins manage achievements" ON public.user_achievements FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

-- House wallet
CREATE TABLE IF NOT EXISTS public.house_wallet (
  id integer PRIMARY KEY DEFAULT 1,
  balance bigint NOT NULL DEFAULT 0,
  total_in bigint NOT NULL DEFAULT 0,
  total_out bigint NOT NULL DEFAULT 0,
  payouts_paused boolean NOT NULL DEFAULT false,
  pause_reason text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT house_wallet_singleton CHECK (id = 1)
);
INSERT INTO public.house_wallet (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.house_wallet ENABLE ROW LEVEL SECURITY;
CREATE POLICY "house wallet read admin" ON public.house_wallet FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));
CREATE POLICY "house wallet update admin" ON public.house_wallet FOR UPDATE TO authenticated USING (public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.house_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  kind text NOT NULL, amount bigint NOT NULL, balance_after bigint NOT NULL,
  user_id uuid, bet_id uuid, actor_id uuid, reason text
);
ALTER TABLE public.house_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "house tx admin read" ON public.house_transactions FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

-- Challenges
CREATE TABLE IF NOT EXISTS public.challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('daily','weekly','login')),
  title text NOT NULL, description text,
  reward_tokens bigint NOT NULL DEFAULT 0,
  target_count integer NOT NULL DEFAULT 1,
  action_key text NOT NULL DEFAULT 'manual',
  is_active boolean NOT NULL DEFAULT true,
  starts_at timestamptz, ends_at timestamptz,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.challenges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "challenges read authed" ON public.challenges FOR SELECT TO authenticated USING (true);
CREATE POLICY "challenges admin write" ON public.challenges FOR ALL TO authenticated USING (is_admin(auth.uid())) WITH CHECK (is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.user_challenge_progress (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  challenge_id uuid NOT NULL REFERENCES public.challenges(id) ON DELETE CASCADE,
  progress integer NOT NULL DEFAULT 0,
  completed_at timestamptz, claimed_at timestamptz,
  period_key text NOT NULL DEFAULT to_char(now(),'YYYY-MM-DD'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, challenge_id, period_key)
);
ALTER TABLE public.user_challenge_progress ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ucp own select" ON public.user_challenge_progress FOR SELECT TO authenticated USING (user_id=auth.uid() OR is_admin(auth.uid()));
CREATE POLICY "ucp admin manage" ON public.user_challenge_progress FOR ALL TO authenticated USING (is_admin(auth.uid())) WITH CHECK (is_admin(auth.uid()));

-- Seasons
CREATE TABLE IF NOT EXISTS public.seasons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL, description text, banner_url text,
  starts_at timestamptz NOT NULL DEFAULT now(),
  ends_at timestamptz NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  reward_structure jsonb DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.seasons ENABLE ROW LEVEL SECURITY;
CREATE POLICY "seasons read" ON public.seasons FOR SELECT USING (true);
CREATE POLICY "seasons admin write" ON public.seasons FOR ALL TO authenticated USING (is_admin(auth.uid())) WITH CHECK (is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.season_points (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  season_id uuid NOT NULL REFERENCES public.seasons(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  points integer NOT NULL DEFAULT 0, wins integer NOT NULL DEFAULT 0,
  correct_scores integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season_id, user_id)
);
ALTER TABLE public.season_points ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sp read" ON public.season_points FOR SELECT USING (true);
CREATE POLICY "sp admin write" ON public.season_points FOR ALL TO authenticated USING (is_admin(auth.uid())) WITH CHECK (is_admin(auth.uid()));

-- Watchlist
CREATE TABLE IF NOT EXISTS public.watchlist (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  entity_type text NOT NULL CHECK (entity_type IN ('match','team','player')),
  entity_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, entity_type, entity_id)
);
ALTER TABLE public.watchlist ENABLE ROW LEVEL SECURITY;
CREATE POLICY "watchlist own select" ON public.watchlist FOR SELECT TO authenticated USING (user_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY "watchlist own insert" ON public.watchlist FOR INSERT TO authenticated WITH CHECK (user_id=auth.uid());
CREATE POLICY "watchlist own delete" ON public.watchlist FOR DELETE TO authenticated USING (user_id=auth.uid());

-- Referrals
CREATE TABLE IF NOT EXISTS public.referrals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id uuid NOT NULL,
  referee_id uuid NOT NULL UNIQUE,
  referrer_bonus bigint NOT NULL DEFAULT 0,
  referee_bonus bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "referrals own select" ON public.referrals FOR SELECT TO authenticated USING (referrer_id=auth.uid() OR referee_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY "referrals admin manage" ON public.referrals FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

-- Notification prefs
CREATE TABLE IF NOT EXISTS public.notification_prefs (
  user_id uuid PRIMARY KEY,
  push_enabled boolean NOT NULL DEFAULT true,
  match_starting boolean NOT NULL DEFAULT true,
  bet_results boolean NOT NULL DEFAULT true,
  rewards boolean NOT NULL DEFAULT true,
  daily_streak boolean NOT NULL DEFAULT true,
  referrals boolean NOT NULL DEFAULT true,
  vip_tier_up boolean NOT NULL DEFAULT true,
  withdrawals boolean NOT NULL DEFAULT true,
  promotions boolean NOT NULL DEFAULT true,
  chat_mentions boolean NOT NULL DEFAULT true,
  ticket_replies boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.notification_prefs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "np own all" ON public.notification_prefs FOR ALL TO authenticated USING (user_id=auth.uid() OR public.is_admin(auth.uid())) WITH CHECK (user_id=auth.uid() OR public.is_admin(auth.uid()));

-- Push subscriptions
CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  endpoint text NOT NULL UNIQUE,
  p256dh text NOT NULL, auth_key text NOT NULL,
  user_agent text, enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "push own all" ON public.push_subscriptions FOR ALL TO authenticated USING (user_id=auth.uid() OR public.is_admin(auth.uid())) WITH CHECK (user_id=auth.uid() OR public.is_admin(auth.uid()));

-- User sessions, broadcasts, gang_emblems, friends, spins, gifts
CREATE TABLE IF NOT EXISTS public.user_sessions (
  user_id uuid PRIMARY KEY,
  last_seen timestamptz NOT NULL DEFAULT now(),
  route text, user_agent text
);
ALTER TABLE public.user_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "us own upsert" ON public.user_sessions FOR ALL TO authenticated USING (user_id=auth.uid() OR public.is_admin(auth.uid())) WITH CHECK (user_id=auth.uid() OR public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.broadcasts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL, body text, link text,
  segment text NOT NULL DEFAULT 'all',
  sent_count integer NOT NULL DEFAULT 0,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.broadcasts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "broadcasts admin all" ON public.broadcasts FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));
CREATE POLICY "broadcasts read authed" ON public.broadcasts FOR SELECT TO authenticated USING (true);

CREATE TABLE IF NOT EXISTS public.gang_emblems (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL, image_url text NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  reviewed_by uuid, reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.gang_emblems ENABLE ROW LEVEL SECURITY;
CREATE POLICY "emblems own select" ON public.gang_emblems FOR SELECT TO authenticated USING (user_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY "emblems own insert" ON public.gang_emblems FOR INSERT TO authenticated WITH CHECK (user_id=auth.uid());
CREATE POLICY "emblems admin update" ON public.gang_emblems FOR UPDATE TO authenticated USING (public.is_admin(auth.uid()));
CREATE POLICY "emblems admin delete" ON public.gang_emblems FOR DELETE TO authenticated USING (public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.friends (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  follower_id uuid NOT NULL, followee_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(follower_id, followee_id)
);
ALTER TABLE public.friends ENABLE ROW LEVEL SECURITY;
CREATE POLICY "friends read authed" ON public.friends FOR SELECT TO authenticated USING (true);
CREATE POLICY "friends own insert" ON public.friends FOR INSERT TO authenticated WITH CHECK (follower_id=auth.uid());
CREATE POLICY "friends own delete" ON public.friends FOR DELETE TO authenticated USING (follower_id=auth.uid());

CREATE TABLE IF NOT EXISTS public.spins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL, amount bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.spins ENABLE ROW LEVEL SECURITY;
CREATE POLICY "spins own select" ON public.spins FOR SELECT TO authenticated USING (user_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY "spins own insert" ON public.spins FOR INSERT TO authenticated WITH CHECK (user_id=auth.uid());

CREATE TABLE IF NOT EXISTS public.gifts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid NOT NULL, recipient_id uuid NOT NULL,
  amount bigint NOT NULL, fee bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.gifts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gifts read participants" ON public.gifts FOR SELECT TO authenticated USING (sender_id=auth.uid() OR recipient_id=auth.uid() OR public.is_admin(auth.uid()));
CREATE POLICY "gifts own insert" ON public.gifts FOR INSERT TO authenticated WITH CHECK (sender_id=auth.uid());

-- Spotlights
CREATE TABLE IF NOT EXISTS public.spotlights (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL, headline text NOT NULL, message text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz, is_active boolean NOT NULL DEFAULT true
);
ALTER TABLE public.spotlights ENABLE ROW LEVEL SECURITY;
CREATE POLICY "spotlights public read" ON public.spotlights FOR SELECT USING (true);
CREATE POLICY "spotlights mod write" ON public.spotlights FOR ALL TO authenticated USING (public.is_mod_or_admin(auth.uid())) WITH CHECK (public.is_mod_or_admin(auth.uid()));

-- Promo code requests
CREATE TABLE IF NOT EXISTS public.promo_code_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  amount bigint NOT NULL CHECK (amount > 0),
  usage_limit integer NOT NULL DEFAULT 1 CHECK (usage_limit > 0),
  reason text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','declined')),
  generated_code text, promo_id uuid, admin_note text,
  reviewed_by uuid, reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.promo_code_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sponsors create own requests" ON public.promo_code_requests FOR INSERT TO authenticated WITH CHECK (auth.uid()=user_id AND public.has_role(auth.uid(), 'sponsor'));
CREATE POLICY "users see own promo requests" ON public.promo_code_requests FOR SELECT TO authenticated USING (auth.uid()=user_id OR public.is_admin(auth.uid()));
CREATE POLICY "admins update promo requests" ON public.promo_code_requests FOR UPDATE TO authenticated USING (public.is_admin(auth.uid()));
CREATE POLICY "admins delete promo requests" ON public.promo_code_requests FOR DELETE TO authenticated USING (public.is_admin(auth.uid()));

-- Views
CREATE OR REPLACE VIEW public.hot_bets_v1 WITH (security_invoker=on) AS
SELECT bs.match_id, m.name AS match_name, mk.name AS market_name, bs.selection_label,
  AVG(bs.locked_odds)::numeric(10,2) AS avg_odds,
  COUNT(DISTINCT b.user_id) AS users_count,
  COUNT(*) AS bets_count,
  SUM(b.stake)::bigint AS total_stake,
  MAX(b.created_at) AS last_bet_at
FROM bet_selections bs
JOIN bets b ON b.id=bs.bet_id
JOIN markets mk ON mk.id=bs.market_id
LEFT JOIN matches m ON m.id=bs.match_id
WHERE b.created_at > now() - interval '7 days' AND b.status IN ('open','won','lost')
GROUP BY bs.match_id, m.name, mk.name, bs.selection_label;
GRANT SELECT ON public.hot_bets_v1 TO authenticated, anon;

CREATE OR REPLACE VIEW public.promo_code_usage_v2 WITH (security_invoker=on) AS
SELECT r.id AS redemption_id, r.promo_id, pc.code, pc.amount AS code_amount,
  r.amount AS redeemed_amount, r.created_at AS redeemed_at, r.user_id,
  p.full_name, p.email, p.ingame_name, p.gang_name
FROM public.promo_redemptions r
JOIN public.promo_codes pc ON pc.id=r.promo_id
LEFT JOIN public.profiles p ON p.id=r.user_id;
GRANT SELECT ON public.promo_code_usage_v2 TO authenticated;

CREATE OR REPLACE VIEW public.promo_code_usage_log WITH (security_invoker=on) AS
SELECT pc.id AS promo_id, pc.code, pc.amount, pc.created_by, pc.expires_at,
  pc.created_at AS generated_at, creator.full_name AS generated_by_name,
  creator.email AS generated_by_email, pc.is_active, pc.max_uses, pc.target_user_ids,
  pc.usage_limit, pc.used_count, r.id AS redemption_id, r.created_at AS used_at,
  r.user_id AS used_by, used.full_name AS used_by_name, used.email AS used_by_email,
  used.gang_name AS used_by_gang_name
FROM public.promo_codes pc
LEFT JOIN public.promo_redemptions r ON r.promo_id=pc.id
LEFT JOIN public.profiles creator ON creator.id=pc.created_by
LEFT JOIN public.profiles used ON used.id=r.user_id;
GRANT SELECT ON public.promo_code_usage_log TO authenticated;

-- Core RPCs (subset used by client)
CREATE OR REPLACE FUNCTION public.redeem_promo_code(_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE uid uuid := auth.uid(); p record; user_uses int; new_balance bigint;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO p FROM public.promo_codes WHERE code=upper(_code) FOR UPDATE;
  IF p IS NULL THEN RAISE EXCEPTION 'Invalid code'; END IF;
  IF NOT p.is_active THEN RAISE EXCEPTION 'Code is inactive'; END IF;
  IF p.expires_at IS NOT NULL AND p.expires_at < now() THEN RAISE EXCEPTION 'Code has expired'; END IF;
  IF p.target_user_ids IS NOT NULL AND array_length(p.target_user_ids,1)>0 AND NOT (uid = ANY(p.target_user_ids)) THEN
    RAISE EXCEPTION 'This code is not available for your account';
  END IF;
  IF p.max_uses IS NOT NULL AND p.used_count >= p.max_uses THEN RAISE EXCEPTION 'Maxed out'; END IF;
  SELECT count(*) INTO user_uses FROM public.promo_redemptions WHERE promo_id=p.id AND user_id=uid;
  IF user_uses >= COALESCE(p.usage_limit,1) THEN RAISE EXCEPTION 'Already used'; END IF;
  INSERT INTO public.promo_redemptions(promo_id,user_id,amount) VALUES (p.id,uid,p.amount);
  UPDATE public.promo_codes SET used_count=used_count+1 WHERE id=p.id;
  UPDATE public.profiles SET token_balance=token_balance+p.amount WHERE id=uid RETURNING token_balance INTO new_balance;
  INSERT INTO public.token_transactions(user_id,amount,balance_after,kind,description) VALUES (uid,p.amount,new_balance,'promo','Promo: '||p.code);
  INSERT INTO public.notifications(user_id,title,body) VALUES (uid,'Promo redeemed','+'||p.amount||' tokens');
  RETURN jsonb_build_object('amount',p.amount,'balance',new_balance,'code',p.code);
END $$;
GRANT EXECUTE ON FUNCTION public.redeem_promo_code(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_daily_login() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE uid uuid:=auth.uid(); p record; cfg record; total bigint; today date:=(now() at time zone 'utc')::date; new_streak int; new_balance bigint;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT daily_login_enabled,daily_login_base_reward,daily_login_bonus_per_day,daily_login_max_streak INTO cfg FROM app_settings WHERE id=1;
  IF NOT COALESCE(cfg.daily_login_enabled,true) THEN RAISE EXCEPTION 'Paused'; END IF;
  SELECT * INTO p FROM profiles WHERE id=uid FOR UPDATE;
  IF p.last_login_date=today THEN RETURN jsonb_build_object('already_claimed',true,'streak',p.streak_days); END IF;
  IF p.last_login_date=today-1 THEN new_streak:=p.streak_days+1; ELSE new_streak:=1; END IF;
  total:=(COALESCE(cfg.daily_login_base_reward,100000) * (1 + LEAST(new_streak,COALESCE(cfg.daily_login_max_streak,30)) * COALESCE(cfg.daily_login_bonus_per_day,0.1)))::bigint;
  UPDATE profiles SET streak_days=new_streak, longest_streak=GREATEST(longest_streak,new_streak), last_login_date=today, token_balance=token_balance+total WHERE id=uid RETURNING token_balance INTO new_balance;
  INSERT INTO token_transactions(user_id,amount,balance_after,kind,description) VALUES (uid,total,new_balance,'daily_login','Day '||new_streak);
  INSERT INTO notifications(user_id,title,body) VALUES (uid,'🔥 Day '||new_streak||' streak!','+'||total||' tokens');
  RETURN jsonb_build_object('reward',total,'streak',new_streak,'balance',new_balance);
END $$;
GRANT EXECUTE ON FUNCTION public.claim_daily_login() TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_challenge(_progress_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE uid uuid:=auth.uid(); ucp record; ch record; new_balance bigint;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO ucp FROM user_challenge_progress WHERE id=_progress_id FOR UPDATE;
  IF ucp IS NULL OR ucp.user_id<>uid THEN RAISE EXCEPTION 'Not found'; END IF;
  IF ucp.claimed_at IS NOT NULL THEN RAISE EXCEPTION 'Already claimed'; END IF;
  IF ucp.completed_at IS NULL THEN RAISE EXCEPTION 'Not completed'; END IF;
  SELECT * INTO ch FROM challenges WHERE id=ucp.challenge_id;
  UPDATE user_challenge_progress SET claimed_at=now() WHERE id=_progress_id;
  UPDATE profiles SET token_balance=token_balance+ch.reward_tokens WHERE id=uid RETURNING token_balance INTO new_balance;
  INSERT INTO token_transactions(user_id,amount,balance_after,kind,description) VALUES (uid,ch.reward_tokens,new_balance,'challenge',ch.title);
  RETURN jsonb_build_object('reward',ch.reward_tokens,'balance',new_balance);
END $$;
GRANT EXECUTE ON FUNCTION public.claim_challenge(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_task(_task_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE t public.user_tasks%ROWTYPE; uid uuid:=auth.uid(); new_balance bigint;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO t FROM user_tasks WHERE id=_task_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not found'; END IF;
  IF t.user_id<>uid THEN RAISE EXCEPTION 'Not yours'; END IF;
  IF t.status='claimed' THEN RAISE EXCEPTION 'Already claimed'; END IF;
  IF t.status<>'completed' THEN RAISE EXCEPTION 'Not completed'; END IF;
  UPDATE user_tasks SET status='claimed', completed_at=COALESCE(completed_at,now()) WHERE id=_task_id;
  UPDATE profiles SET token_balance=token_balance+t.reward_tokens WHERE id=uid RETURNING token_balance INTO new_balance;
  INSERT INTO token_transactions(user_id,amount,balance_after,kind,description) VALUES (uid,t.reward_tokens,new_balance,'task_reward',t.title);
  RETURN jsonb_build_object('ok',true,'reward',t.reward_tokens,'balance',new_balance);
END $$;
GRANT EXECUTE ON FUNCTION public.claim_task(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.apply_referral_code(_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE uid uuid:=auth.uid(); ref record; me record; b1 bigint; b2 bigint;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO me FROM profiles WHERE id=uid FOR UPDATE;
  IF me.referred_by IS NOT NULL THEN RAISE EXCEPTION 'Already used'; END IF;
  SELECT * INTO ref FROM profiles WHERE referral_code=upper(_code) AND id<>uid;
  IF ref IS NULL THEN RAISE EXCEPTION 'Invalid'; END IF;
  SELECT referral_bonus_referrer,referral_bonus_referee INTO b1,b2 FROM app_settings WHERE id=1;
  INSERT INTO referrals(referrer_id,referee_id,referrer_bonus,referee_bonus) VALUES (ref.id,uid,b1,b2);
  UPDATE profiles SET referred_by=ref.id, token_balance=token_balance+b2 WHERE id=uid;
  UPDATE profiles SET token_balance=token_balance+b1 WHERE id=ref.id;
  RETURN jsonb_build_object('referee_bonus',b2,'referrer_bonus',b1);
END $$;
GRANT EXECUTE ON FUNCTION public.apply_referral_code(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.user_cashout_bet(_bet_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE b record; new_bal bigint; paused boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT payouts_paused INTO paused FROM house_wallet WHERE id=1;
  IF paused THEN RAISE EXCEPTION 'Payouts paused'; END IF;
  SELECT * INTO b FROM bets WHERE id=_bet_id FOR UPDATE;
  IF b IS NULL OR b.user_id<>auth.uid() THEN RAISE EXCEPTION 'Bad'; END IF;
  IF b.status<>'open' THEN RAISE EXCEPTION 'Not open'; END IF;
  UPDATE profiles SET token_balance=token_balance+b.potential_payout WHERE id=b.user_id RETURNING token_balance INTO new_bal;
  UPDATE bets SET status='won', cashout_amount=b.potential_payout, cashed_out_at=now(), settled_at=now() WHERE id=_bet_id;
  RETURN jsonb_build_object('credited',b.potential_payout,'balance',new_bal);
END $$;
GRANT EXECUTE ON FUNCTION public.user_cashout_bet(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_withdrawal_request(_amount bigint, _ingame text, _gang text, _ticket text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE uid uuid:=auth.uid(); bal bigint; req_id uuid; min_amt bigint;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT COALESCE(min_withdrawal,2000000) INTO min_amt FROM app_settings WHERE id=1;
  IF _amount IS NULL OR _amount<=0 OR _amount<min_amt THEN RAISE EXCEPTION 'Bad amount'; END IF;
  SELECT token_balance INTO bal FROM profiles WHERE id=uid FOR UPDATE;
  IF bal IS NULL OR bal<_amount THEN RAISE EXCEPTION 'Insufficient'; END IF;
  UPDATE profiles SET token_balance=token_balance-_amount WHERE id=uid;
  INSERT INTO withdrawal_requests(user_id,ingame_name,gang_name,amount,ticket_ref) VALUES (uid,_ingame,_gang,_amount,_ticket) RETURNING id INTO req_id;
  RETURN req_id;
END $$;
GRANT EXECUTE ON FUNCTION public.create_withdrawal_request(bigint,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.review_withdrawal_request(_id uuid, _approve boolean, _note text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r record;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO r FROM withdrawal_requests WHERE id=_id FOR UPDATE;
  IF r.status<>'pending' THEN RAISE EXCEPTION 'Reviewed'; END IF;
  IF _approve THEN
    UPDATE withdrawal_requests SET status='approved',admin_note=_note,reviewed_by=auth.uid(),reviewed_at=now() WHERE id=_id;
  ELSE
    UPDATE profiles SET token_balance=token_balance+r.amount WHERE id=r.user_id;
    UPDATE withdrawal_requests SET status='declined',admin_note=_note,reviewed_by=auth.uid(),reviewed_at=now() WHERE id=_id;
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.review_withdrawal_request(uuid,boolean,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_risk_summary() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE hw record; exposure bigint; open_bets int; pending_wd int;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  SELECT balance,payouts_paused INTO hw FROM house_wallet WHERE id=1;
  SELECT COALESCE(SUM(potential_payout-stake),0), COUNT(*) INTO exposure,open_bets FROM bets WHERE status='open';
  SELECT COUNT(*) INTO pending_wd FROM withdrawal_requests WHERE status='pending';
  RETURN jsonb_build_object('house_balance',hw.balance,'payouts_paused',hw.payouts_paused,'total_exposure',exposure,'open_bets',open_bets,'pending_withdrawals',pending_wd);
END $$;
GRANT EXECUTE ON FUNCTION public.admin_risk_summary() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_pnl_summary(_days integer DEFAULT 30) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE since timestamptz:=now()-(_days||' days')::interval; stakes_in bigint; payouts_out bigint; bets_count int; wins_count int;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  SELECT COALESCE(SUM(stake),0),COUNT(*) INTO stakes_in,bets_count FROM bets WHERE created_at>=since;
  SELECT COALESCE(SUM(potential_payout),0),COUNT(*) INTO payouts_out,wins_count FROM bets WHERE status='won' AND created_at>=since;
  RETURN jsonb_build_object('stakes_in',stakes_in,'payouts_out',payouts_out,'net',stakes_in-payouts_out,'bets',bets_count,'wins',wins_count);
END $$;
GRANT EXECUTE ON FUNCTION public.admin_pnl_summary(integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_exposure_per_match() RETURNS TABLE(match_id uuid, match_name text, bet_count int, exposure bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  RETURN QUERY SELECT m.id, m.name, COUNT(DISTINCT b.id)::int, COALESCE(SUM(b.potential_payout-b.stake),0)::bigint
    FROM matches m JOIN bet_selections bs ON bs.match_id=m.id JOIN bets b ON b.id=bs.bet_id
    WHERE b.status='open' GROUP BY m.id, m.name ORDER BY 4 DESC LIMIT 30;
END $$;
GRANT EXECUTE ON FUNCTION public.admin_exposure_per_match() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_broadcast(_title text, _body text, _link text, _segment text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE sent int:=0; r record;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  FOR r IN SELECT p.id FROM profiles p WHERE CASE WHEN _segment='vip' THEN p.vip_tier IN ('gold','platinum','legend') WHEN _segment='admins' THEN EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id=p.id AND ur.role='admin') ELSE true END LOOP
    INSERT INTO notifications(user_id,title,body,link) VALUES (r.id,_title,NULLIF(_body,''),NULLIF(_link,''));
    sent:=sent+1;
  END LOOP;
  INSERT INTO broadcasts(title,body,link,segment,sent_count,created_by) VALUES (_title,_body,_link,_segment,sent,auth.uid());
  RETURN jsonb_build_object('sent',sent);
END $$;
GRANT EXECUTE ON FUNCTION public.admin_broadcast(text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_award_achievement(_user_id uuid, _code text, _title text, _description text DEFAULT NULL, _icon text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE new_id uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  INSERT INTO user_achievements(user_id,code,title,description,icon) VALUES (_user_id,_code,_title,_description,_icon) RETURNING id INTO new_id;
  RETURN new_id;
END $$;
GRANT EXECUTE ON FUNCTION public.admin_award_achievement(uuid,text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_adjust_xp(_user_id uuid, _delta integer, _reason text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE new_xp bigint; new_tier text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  UPDATE profiles SET xp=GREATEST(0,xp+_delta) WHERE id=_user_id RETURNING xp INTO new_xp;
  new_tier:=CASE WHEN new_xp>=25000 THEN 'legend' WHEN new_xp>=10000 THEN 'platinum' WHEN new_xp>=3000 THEN 'gold' WHEN new_xp>=500 THEN 'silver' ELSE 'bronze' END;
  UPDATE profiles SET vip_tier=new_tier WHERE id=_user_id;
  RETURN jsonb_build_object('xp',new_xp,'vip_tier',new_tier);
END $$;
GRANT EXECUTE ON FUNCTION public.admin_adjust_xp(uuid,integer,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_mark_task_completed(_task_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  UPDATE user_tasks SET status='completed',completed_at=now() WHERE id=_task_id AND status='pending';
END $$;
GRANT EXECUTE ON FUNCTION public.admin_mark_task_completed(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_suspend_bet(_bet_id uuid, _reason text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  UPDATE bets SET status='suspended' WHERE id=_bet_id;
END $$;
GRANT EXECUTE ON FUNCTION public.admin_suspend_bet(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_unsuspend_bet(_bet_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  UPDATE bets SET status='open' WHERE id=_bet_id AND status='suspended';
END $$;
GRANT EXECUTE ON FUNCTION public.admin_unsuspend_bet(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_delete_bet(_bet_id uuid, _refund boolean DEFAULT false, _reason text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE b record;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  SELECT * INTO b FROM bets WHERE id=_bet_id FOR UPDATE;
  IF _refund AND b.status NOT IN ('refunded','won','cashed_out','void') THEN
    UPDATE profiles SET token_balance=token_balance+b.stake WHERE id=b.user_id;
  END IF;
  DELETE FROM bet_selections WHERE bet_id=_bet_id;
  DELETE FROM bets WHERE id=_bet_id;
END $$;
GRANT EXECUTE ON FUNCTION public.admin_delete_bet(uuid,boolean,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.house_set_paused(_paused boolean, _reason text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  UPDATE house_wallet SET payouts_paused=_paused,pause_reason=_reason,updated_at=now() WHERE id=1;
END $$;
GRANT EXECUTE ON FUNCTION public.house_set_paused(boolean,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.house_manual_adjust(_amount bigint, _reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE new_bal bigint;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  UPDATE house_wallet SET balance=balance+_amount, total_in=total_in+GREATEST(_amount,0), total_out=total_out+GREATEST(-_amount,0), updated_at=now() WHERE id=1 RETURNING balance INTO new_bal;
  INSERT INTO house_transactions(kind,amount,balance_after,actor_id,reason) VALUES (CASE WHEN _amount>0 THEN 'manual_credit' ELSE 'manual_debit' END,_amount,new_bal,auth.uid(),_reason);
  RETURN jsonb_build_object('balance',new_bal);
END $$;
GRANT EXECUTE ON FUNCTION public.house_manual_adjust(bigint,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.approve_promo_request(_id uuid, _note text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r record; new_code text; new_promo uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  SELECT * INTO r FROM promo_code_requests WHERE id=_id FOR UPDATE;
  new_code:='LSL-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  INSERT INTO promo_codes(code,amount,usage_limit,used_count,is_active,created_by) VALUES (new_code,r.amount,r.usage_limit,0,true,auth.uid()) RETURNING id INTO new_promo;
  UPDATE promo_code_requests SET status='approved',generated_code=new_code,promo_id=new_promo,admin_note=_note,reviewed_by=auth.uid(),reviewed_at=now() WHERE id=_id;
  RETURN new_promo;
END $$;
GRANT EXECUTE ON FUNCTION public.approve_promo_request(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.decline_promo_request(_id uuid, _note text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  UPDATE promo_code_requests SET status='declined',admin_note=_note,reviewed_by=auth.uid(),reviewed_at=now() WHERE id=_id AND status='pending';
END $$;
GRANT EXECUTE ON FUNCTION public.decline_promo_request(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.review_gang_emblem(_id uuid, _approve boolean, _note text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE e record;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  SELECT * INTO e FROM gang_emblems WHERE id=_id FOR UPDATE;
  UPDATE gang_emblems SET status=CASE WHEN _approve THEN 'approved' ELSE 'rejected' END, reviewed_by=auth.uid(), reviewed_at=now() WHERE id=_id;
  IF _approve THEN UPDATE profiles SET gang_emblem_url=e.image_url,emblem_status='approved' WHERE id=e.user_id;
  ELSE UPDATE profiles SET emblem_status='rejected' WHERE id=e.user_id; END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.review_gang_emblem(uuid,boolean,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.wipe_all_tokens() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  UPDATE profiles SET token_balance=0 WHERE token_balance>0;
END $$;
GRANT EXECUTE ON FUNCTION public.wipe_all_tokens() TO authenticated;

CREATE OR REPLACE FUNCTION public.recalc_vip_tier(_user_id uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE cur_xp bigint; new_tier text;
BEGIN
  SELECT xp INTO cur_xp FROM profiles WHERE id=_user_id;
  new_tier:=CASE WHEN cur_xp>=25000 THEN 'legend' WHEN cur_xp>=10000 THEN 'platinum' WHEN cur_xp>=3000 THEN 'gold' WHEN cur_xp>=500 THEN 'silver' ELSE 'bronze' END;
  UPDATE profiles SET vip_tier=new_tier WHERE id=_user_id;
  RETURN new_tier;
END $$;

CREATE OR REPLACE FUNCTION public.verify_xp_consistency(_user_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE checked int:=0; fixed int:=0;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin'; END IF;
  RETURN jsonb_build_object('checked',checked,'fixed',fixed);
END $$;
GRANT EXECUTE ON FUNCTION public.verify_xp_consistency(uuid) TO authenticated;

-- Realtime
DO $$ DECLARE t TEXT; BEGIN
  FOR t IN SELECT unnest(ARRAY['matches','odds','markets','chat_messages','ticket_messages','notifications','support_tickets','bets','bet_selections','profiles','advertisements','highlights','announcements','events','token_requests','token_transactions','app_settings','ban_appeals','withdrawal_requests','spotlights']) LOOP
    BEGIN EXECUTE format('ALTER TABLE public.%I REPLICA IDENTITY FULL', t); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $$;
