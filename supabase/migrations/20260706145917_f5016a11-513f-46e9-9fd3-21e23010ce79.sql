
CREATE OR REPLACE FUNCTION public.touch_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

CREATE TABLE public.promo_slides (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  subtitle TEXT,
  image_url TEXT NOT NULL,
  cta_label TEXT,
  cta_link TEXT,
  sort_order INT NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.promo_slides TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.promo_slides TO authenticated;
GRANT ALL ON public.promo_slides TO service_role;
ALTER TABLE public.promo_slides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "promo_slides_read_all" ON public.promo_slides FOR SELECT USING (true);
CREATE POLICY "promo_slides_admin_write" ON public.promo_slides FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'moderator'))
  WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'moderator'));
CREATE TRIGGER promo_slides_touch BEFORE UPDATE ON public.promo_slides
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.sidebar_categories (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  icon TEXT,
  link TEXT,
  sort_order INT NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  is_pinned BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.sidebar_categories TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sidebar_categories TO authenticated;
GRANT ALL ON public.sidebar_categories TO service_role;
ALTER TABLE public.sidebar_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sidebar_categories_read_all" ON public.sidebar_categories FOR SELECT USING (true);
CREATE POLICY "sidebar_categories_admin_write" ON public.sidebar_categories FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'moderator'))
  WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'moderator'));
CREATE TRIGGER sidebar_categories_touch BEFORE UPDATE ON public.sidebar_categories
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

INSERT INTO public.sidebar_categories (name, icon, link, sort_order, is_pinned) VALUES
  ('Live Shootouts', 'flame', '/matches', 10, true),
  ('Virtual Arena', 'dice', '/virtual', 20, true),
  ('Tournaments', 'trophy', '/tournaments', 30, true),
  ('Leaderboard', 'crown', '/leaderboard', 40, true),
  ('Gangs', 'skull', '/gangs', 50, false),
  ('Featured Battles', 'crosshair', '/matches', 60, false),
  ('Head-to-Head', 'swords', '/matches', 70, false),
  ('Grand Prize', 'gift', '/leaderboard', 80, false),
  ('Challenges', 'target', '/tasks', 90, false),
  ('Watchlist', 'star', '/watchlist', 100, false);
