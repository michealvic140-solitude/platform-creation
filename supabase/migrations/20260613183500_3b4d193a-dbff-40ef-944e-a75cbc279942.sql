DROP VIEW IF EXISTS public.public_profiles;

CREATE OR REPLACE FUNCTION public.public_profiles(_ids uuid[] DEFAULT NULL)
RETURNS TABLE(
  id uuid,
  full_name text,
  ingame_name text,
  gang_name text,
  gang_type text,
  vip_tier text,
  xp bigint,
  streak_days integer,
  longest_streak integer,
  profile_title text,
  avatar_url text,
  country text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id, full_name, ingame_name, gang_name, gang_type::text, vip_tier, xp,
         streak_days, longest_streak, profile_title, avatar_url, country
  FROM public.profiles
  WHERE _ids IS NULL OR id = ANY(_ids)
  ORDER BY full_name
$$;
GRANT EXECUTE ON FUNCTION public.public_profiles(uuid[]) TO anon, authenticated;