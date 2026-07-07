
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

CREATE TABLE public.home_popular_links (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  label TEXT NOT NULL,
  target_url TEXT NOT NULL,
  icon TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.home_popular_links TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.home_popular_links TO authenticated;
GRANT ALL ON public.home_popular_links TO service_role;
ALTER TABLE public.home_popular_links ENABLE ROW LEVEL SECURITY;
CREATE POLICY "hp_read" ON public.home_popular_links FOR SELECT USING (true);
CREATE POLICY "hp_admin" ON public.home_popular_links FOR ALL
  USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_hp_updated BEFORE UPDATE ON public.home_popular_links
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.home_hero_slides (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  image_url TEXT NOT NULL,
  title TEXT, subtitle TEXT, cta_label TEXT, cta_url TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.home_hero_slides TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.home_hero_slides TO authenticated;
GRANT ALL ON public.home_hero_slides TO service_role;
ALTER TABLE public.home_hero_slides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "hh_read" ON public.home_hero_slides FOR SELECT USING (true);
CREATE POLICY "hh_admin" ON public.home_hero_slides FOR ALL
  USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_hh_updated BEFORE UPDATE ON public.home_hero_slides
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.home_featured_tiles (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  tab TEXT NOT NULL CHECK (tab IN ('featured','highlight','gifts')),
  image_url TEXT NOT NULL,
  title TEXT, cta_label TEXT, cta_url TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.home_featured_tiles TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.home_featured_tiles TO authenticated;
GRANT ALL ON public.home_featured_tiles TO service_role;
ALTER TABLE public.home_featured_tiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "hf_read" ON public.home_featured_tiles FOR SELECT USING (true);
CREATE POLICY "hf_admin" ON public.home_featured_tiles FOR ALL
  USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_hf_updated BEFORE UPDATE ON public.home_featured_tiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.home_news_posts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  image_url TEXT,
  title TEXT NOT NULL,
  body TEXT, link_url TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.home_news_posts TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.home_news_posts TO authenticated;
GRANT ALL ON public.home_news_posts TO service_role;
ALTER TABLE public.home_news_posts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "hn_read" ON public.home_news_posts FOR SELECT USING (true);
CREATE POLICY "hn_admin" ON public.home_news_posts FOR ALL
  USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_hn_updated BEFORE UPDATE ON public.home_news_posts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.home_lottery_draws (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  prize_label TEXT,
  ends_at TIMESTAMPTZ,
  cta_label TEXT DEFAULT 'Buy Now',
  cta_url TEXT,
  numbers INTEGER[] DEFAULT '{}',
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.home_lottery_draws TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.home_lottery_draws TO authenticated;
GRANT ALL ON public.home_lottery_draws TO service_role;
ALTER TABLE public.home_lottery_draws ENABLE ROW LEVEL SECURITY;
CREATE POLICY "hld_read" ON public.home_lottery_draws FOR SELECT USING (true);
CREATE POLICY "hld_admin" ON public.home_lottery_draws FOR ALL
  USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_hld_updated BEFORE UPDATE ON public.home_lottery_draws
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.home_lottery_results (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  draw_name TEXT NOT NULL,
  draw_no TEXT,
  numbers INTEGER[] NOT NULL DEFAULT '{}',
  winnings_label TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.home_lottery_results TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.home_lottery_results TO authenticated;
GRANT ALL ON public.home_lottery_results TO service_role;
ALTER TABLE public.home_lottery_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY "hlr_read" ON public.home_lottery_results FOR SELECT USING (true);
CREATE POLICY "hlr_admin" ON public.home_lottery_results FOR ALL
  USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_hlr_updated BEFORE UPDATE ON public.home_lottery_results
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
