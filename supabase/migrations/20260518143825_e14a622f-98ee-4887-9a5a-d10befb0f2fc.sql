
-- 1. Staging table
CREATE TABLE IF NOT EXISTS public.imported_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid,
  email text NOT NULL,
  full_name text,
  phone text,
  discord_username text,
  discord_full_name text,
  ingame_name text,
  country text,
  server text,
  gang_name text,
  gang_type public.gang_type,
  token_balance bigint DEFAULT 0,
  xp bigint DEFAULT 0,
  vip_tier text,
  streak_days int DEFAULT 0,
  longest_streak int DEFAULT 0,
  last_login_date date,
  referral_code text,
  claimed_at timestamptz,
  claimed_user_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS imported_profiles_email_lower_idx
  ON public.imported_profiles (lower(email));

ALTER TABLE public.imported_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read imported_profiles"
  ON public.imported_profiles FOR SELECT
  USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins manage imported_profiles"
  ON public.imported_profiles FOR ALL
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

-- 2. Helper to apply imported data to an existing profile
CREATE OR REPLACE FUNCTION public.apply_imported_profile(_user_id uuid, _email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE imp record;
BEGIN
  SELECT * INTO imp FROM public.imported_profiles
    WHERE lower(email) = lower(_email) AND claimed_at IS NULL
    LIMIT 1;
  IF imp IS NULL THEN RETURN false; END IF;

  UPDATE public.profiles SET
    full_name = COALESCE(NULLIF(imp.full_name,''), full_name),
    phone = COALESCE(NULLIF(imp.phone,''), phone),
    discord_username = COALESCE(NULLIF(imp.discord_username,''), discord_username),
    discord_full_name = COALESCE(NULLIF(imp.discord_full_name,''), discord_full_name),
    ingame_name = COALESCE(NULLIF(imp.ingame_name,''), ingame_name),
    country = COALESCE(NULLIF(imp.country,''), country),
    server = COALESCE(NULLIF(imp.server,''), server),
    gang_name = COALESCE(NULLIF(imp.gang_name,''), gang_name),
    gang_type = COALESCE(imp.gang_type, gang_type),
    token_balance = GREATEST(token_balance, COALESCE(imp.token_balance, 0)),
    xp = GREATEST(xp, COALESCE(imp.xp, 0)),
    vip_tier = COALESCE(NULLIF(imp.vip_tier,''), vip_tier),
    streak_days = GREATEST(streak_days, COALESCE(imp.streak_days, 0)),
    longest_streak = GREATEST(longest_streak, COALESCE(imp.longest_streak, 0)),
    last_login_date = COALESCE(imp.last_login_date, last_login_date),
    referral_code = COALESCE(referral_code, NULLIF(imp.referral_code,''))
  WHERE id = _user_id;

  UPDATE public.imported_profiles
    SET claimed_at = now(), claimed_user_id = _user_id
    WHERE id = imp.id;

  INSERT INTO public.notifications(user_id, title, body)
    VALUES (_user_id, 'Welcome back!', 'Your previous account data has been restored: ' || COALESCE(imp.token_balance,0) || ' tokens, ' || COALESCE(imp.xp,0) || ' XP.');

  RETURN true;
END $$;

-- 3. Patch handle_new_user to also restore imported data
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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

  -- Restore data from old project, if any
  PERFORM public.apply_imported_profile(NEW.id, NEW.email);

  RETURN NEW;
END $$;
