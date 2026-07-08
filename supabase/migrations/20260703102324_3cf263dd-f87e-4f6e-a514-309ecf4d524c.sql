
-- Generic updated_at helper (safe create)
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

-- 1) Home banners (sliding promo banners below the navbar)
CREATE TABLE IF NOT EXISTS public.home_banners (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL DEFAULT '',
  subtitle text NOT NULL DEFAULT '',
  image_url text NOT NULL,
  link_url text NOT NULL DEFAULT '/',
  cta_label text NOT NULL DEFAULT 'Click here',
  is_active boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.home_banners TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.home_banners TO authenticated;
GRANT ALL ON public.home_banners TO service_role;
ALTER TABLE public.home_banners ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can view active banners" ON public.home_banners;
CREATE POLICY "Anyone can view active banners" ON public.home_banners
  FOR SELECT USING (is_active = true OR public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins manage banners" ON public.home_banners;
CREATE POLICY "Admins manage banners" ON public.home_banners
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));
DROP TRIGGER IF EXISTS t_home_banners_updated ON public.home_banners;
CREATE TRIGGER t_home_banners_updated BEFORE UPDATE ON public.home_banners
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 2) Recurring push blasts
ALTER TABLE public.scheduled_pushes ADD COLUMN IF NOT EXISTS repeat_interval text NOT NULL DEFAULT 'none';
ALTER TABLE public.scheduled_pushes DROP CONSTRAINT IF EXISTS scheduled_pushes_repeat_chk;
ALTER TABLE public.scheduled_pushes ADD CONSTRAINT scheduled_pushes_repeat_chk
  CHECK (repeat_interval IN ('none','daily','weekly'));

-- 3) Store the broadcast push endpoint URL for DB-triggered global pushes
ALTER TABLE public.app_settings_private ADD COLUMN IF NOT EXISTS broadcast_endpoint_url text;

-- 4) Achievements awarded automatically on VIP tier / rank-up
DELETE FROM public.user_achievements a
  USING public.user_achievements b
  WHERE a.ctid < b.ctid AND a.user_id = b.user_id AND a.code = b.code;
CREATE UNIQUE INDEX IF NOT EXISTS user_achievements_user_code_uniq
  ON public.user_achievements(user_id, code);

CREATE OR REPLACE FUNCTION public.award_tier_achievement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.vip_tier IS DISTINCT FROM OLD.vip_tier AND NEW.vip_tier IS NOT NULL THEN
    INSERT INTO public.user_achievements(user_id, code, title, description, icon)
    VALUES (NEW.id, 'tier_' || NEW.vip_tier, initcap(NEW.vip_tier) || ' Rank Unlocked',
            'You ranked up to the ' || initcap(NEW.vip_tier) || ' VIP tier.', '👑')
    ON CONFLICT (user_id, code) DO NOTHING;

    INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (NEW.id, '👑 Rank up! You are now ' || initcap(NEW.vip_tier),
            'A new achievement was added to your collection.', '/achievements');
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS t_award_tier_ach ON public.profiles;
CREATE TRIGGER t_award_tier_ach AFTER UPDATE OF vip_tier ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.award_tier_achievement();

-- 5) Global device push when a real match goes live / a new real match is posted
CREATE OR REPLACE FUNCTION public.notify_match_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_url text;
BEGIN
  IF NEW.is_virtual IS TRUE THEN RETURN NEW; END IF;
  SELECT broadcast_endpoint_url INTO v_url FROM public.app_settings_private WHERE id = 1;
  IF v_url IS NULL OR length(trim(v_url)) = 0 THEN RETURN NEW; END IF;

  IF TG_OP = 'UPDATE' AND NEW.status = 'live' AND OLD.status IS DISTINCT FROM 'live' THEN
    PERFORM net.http_post(url := v_url,
      body := jsonb_build_object('kind','match_live','id',NEW.id),
      headers := jsonb_build_object('Content-Type','application/json'),
      timeout_milliseconds := 5000);
  ELSIF TG_OP = 'INSERT' AND NEW.status = 'scheduled' THEN
    PERFORM net.http_post(url := v_url,
      body := jsonb_build_object('kind','match_upcoming','id',NEW.id),
      headers := jsonb_build_object('Content-Type','application/json'),
      timeout_milliseconds := 5000);
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS t_notify_match_live ON public.matches;
CREATE TRIGGER t_notify_match_live AFTER UPDATE ON public.matches
  FOR EACH ROW EXECUTE FUNCTION public.notify_match_event();
DROP TRIGGER IF EXISTS t_notify_match_new ON public.matches;
CREATE TRIGGER t_notify_match_new AFTER INSERT ON public.matches
  FOR EACH ROW EXECUTE FUNCTION public.notify_match_event();

-- 6) Global device push when an announcement is posted
CREATE OR REPLACE FUNCTION public.notify_announcement_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_url text;
BEGIN
  IF NEW.is_active IS NOT TRUE THEN RETURN NEW; END IF;
  SELECT broadcast_endpoint_url INTO v_url FROM public.app_settings_private WHERE id = 1;
  IF v_url IS NULL OR length(trim(v_url)) = 0 THEN RETURN NEW; END IF;
  PERFORM net.http_post(url := v_url,
    body := jsonb_build_object('kind','announcement','id',NEW.id),
    headers := jsonb_build_object('Content-Type','application/json'),
    timeout_milliseconds := 5000);
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS t_notify_announcement ON public.announcements;
CREATE TRIGGER t_notify_announcement AFTER INSERT ON public.announcements
  FOR EACH ROW EXECUTE FUNCTION public.notify_announcement_event();
