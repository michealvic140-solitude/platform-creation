-- ============================================================
-- PROFILES: restrict sensitive fields, expose safe display data
-- ============================================================
DROP POLICY IF EXISTS "profiles readable by all authed" ON public.profiles;
CREATE POLICY "profiles own or admin read" ON public.profiles
  FOR SELECT TO authenticated
  USING (auth.uid() = id OR is_admin(auth.uid()));

CREATE OR REPLACE VIEW public.public_profiles AS
  SELECT id, full_name, ingame_name, gang_name, gang_type, vip_tier, xp,
         streak_days, longest_streak, profile_title, avatar_url, country, created_at
  FROM public.profiles;
GRANT SELECT ON public.public_profiles TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.gang_directory()
RETURNS TABLE(name text, type text, members bigint, tokens bigint, sample text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT gang_name,
         max(gang_type),
         count(*),
         coalesce(sum(token_balance), 0)::bigint,
         (array_agg(full_name ORDER BY token_balance DESC NULLS LAST))[1:4]
  FROM public.profiles
  WHERE gang_name IS NOT NULL
  GROUP BY gang_name
$$;
GRANT EXECUTE ON FUNCTION public.gang_directory() TO anon, authenticated;

-- ============================================================
-- USER_ROLES: restrict cross-user reads, expose display badges
-- ============================================================
DROP POLICY IF EXISTS "roles readable by all authed" ON public.user_roles;
CREATE POLICY "user_roles own or admin read" ON public.user_roles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.get_display_roles(_user_id uuid)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(array_agg(role::text), '{}'::text[])
  FROM public.user_roles
  WHERE user_id = _user_id AND role::text IN ('admin', 'moderator');
$$;
GRANT EXECUTE ON FUNCTION public.get_display_roles(uuid) TO anon, authenticated;

-- ============================================================
-- APP_SETTINGS: move sensitive operational fields to admin-only table
-- ============================================================
CREATE TABLE public.app_settings_private (
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

INSERT INTO public.app_settings_private
  (id, admin_ai_model, admin_ai_enabled, exposure_warn_pct, house_low_balance, push_endpoint_url, vapid_subject)
SELECT 1, admin_ai_model, admin_ai_enabled, exposure_warn_pct, house_low_balance, push_endpoint_url, vapid_subject
FROM public.app_settings WHERE id = 1;

GRANT SELECT, INSERT, UPDATE ON public.app_settings_private TO authenticated;
GRANT ALL ON public.app_settings_private TO service_role;
ALTER TABLE public.app_settings_private ENABLE ROW LEVEL SECURITY;
CREATE POLICY "private settings admin" ON public.app_settings_private
  FOR ALL TO authenticated
  USING (is_admin(auth.uid())) WITH CHECK (is_admin(auth.uid()));

ALTER TABLE public.app_settings
  DROP COLUMN admin_ai_model,
  DROP COLUMN admin_ai_enabled,
  DROP COLUMN exposure_warn_pct,
  DROP COLUMN house_low_balance,
  DROP COLUMN push_endpoint_url,
  DROP COLUMN vapid_subject;