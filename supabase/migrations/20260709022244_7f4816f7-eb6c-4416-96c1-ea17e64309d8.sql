
-- =====================================================================
-- Phase 1: Foundational schema for Polls, Shop, FAQ, Lottery, Discord
-- =====================================================================

-- ---------- app_settings: add all missing columns ----------
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS discord_url text,
  ADD COLUMN IF NOT EXISTS discord_support_channel text,
  ADD COLUMN IF NOT EXISTS featured_matches_bg_url text,
  ADD COLUMN IF NOT EXISTS featured_matches_bg_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS lottery_enabled boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS lottery_intro text,
  ADD COLUMN IF NOT EXISTS lottery_min_stake bigint DEFAULT 100000,
  ADD COLUMN IF NOT EXISTS lottery_max_stake bigint DEFAULT 50000000,
  ADD COLUMN IF NOT EXISTS lottery_auto_draw_minutes int DEFAULT 30,
  ADD COLUMN IF NOT EXISTS lottery_num_picks_default int DEFAULT 1,
  ADD COLUMN IF NOT EXISTS polls_enabled boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS shop_enabled boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS hero_bg_url text,
  ADD COLUMN IF NOT EXISTS hero_bg_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS hero_bg_position text DEFAULT 'center',
  ADD COLUMN IF NOT EXISTS hero_title text,
  ADD COLUMN IF NOT EXISTS hero_subtitle text,
  ADD COLUMN IF NOT EXISTS site_name text,
  ADD COLUMN IF NOT EXISTS site_logo_url text,
  ADD COLUMN IF NOT EXISTS site_bg_url text,
  ADD COLUMN IF NOT EXISTS site_bg_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS site_bg_position text DEFAULT 'center',
  ADD COLUMN IF NOT EXISTS nav_bg_url text,
  ADD COLUMN IF NOT EXISTS nav_bg_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS nav_bg_position text DEFAULT 'center';

-- =====================================================================
-- FAQ
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.faqs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question text NOT NULL,
  answer text NOT NULL,
  category text DEFAULT 'General',
  is_active boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.faqs TO anon, authenticated;
GRANT ALL ON public.faqs TO service_role;
ALTER TABLE public.faqs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "faqs read all" ON public.faqs;
CREATE POLICY "faqs read all" ON public.faqs FOR SELECT USING (true);
DROP POLICY IF EXISTS "faqs admin manage" ON public.faqs;
CREATE POLICY "faqs admin manage" ON public.faqs FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- =====================================================================
-- POLLS
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.polls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question text NOT NULL,
  options jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  ends_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.polls TO anon, authenticated;
GRANT ALL ON public.polls TO service_role;
ALTER TABLE public.polls ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "polls read active" ON public.polls;
CREATE POLICY "polls read active" ON public.polls FOR SELECT USING (true);
DROP POLICY IF EXISTS "polls admin manage" ON public.polls;
CREATE POLICY "polls admin manage" ON public.polls FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE TABLE IF NOT EXISTS public.poll_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.polls(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  selected_index int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (poll_id, user_id)
);
GRANT SELECT, INSERT ON public.poll_votes TO authenticated;
GRANT SELECT ON public.poll_votes TO anon;
GRANT ALL ON public.poll_votes TO service_role;
ALTER TABLE public.poll_votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "votes read all" ON public.poll_votes;
CREATE POLICY "votes read all" ON public.poll_votes FOR SELECT USING (true);
DROP POLICY IF EXISTS "votes insert own" ON public.poll_votes;
CREATE POLICY "votes insert own" ON public.poll_votes FOR INSERT
  WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "votes admin manage" ON public.poll_votes;
CREATE POLICY "votes admin manage" ON public.poll_votes FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Admin: remove a specific user's vote
CREATE OR REPLACE FUNCTION public.admin_remove_poll_vote(_vote_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  DELETE FROM public.poll_votes WHERE id = _vote_id;
END $$;

-- Admin: gift tokens to a specific poll voter
CREATE OR REPLACE FUNCTION public.admin_gift_poll_voter(_user_id uuid, _amount bigint, _reason text DEFAULT 'poll gift')
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  UPDATE public.profiles SET token_balance = token_balance + _amount WHERE id = _user_id;
  INSERT INTO public.token_transactions (user_id, delta, reason, created_at)
  VALUES (_user_id, _amount, _reason, now());
END $$;

-- =====================================================================
-- SHOP
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.shop_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  image_url text,
  cost bigint NOT NULL CHECK (cost >= 0),
  stock int,
  is_active boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.shop_items TO anon, authenticated;
GRANT ALL ON public.shop_items TO service_role;
ALTER TABLE public.shop_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "shop items read all" ON public.shop_items;
CREATE POLICY "shop items read all" ON public.shop_items FOR SELECT USING (true);
DROP POLICY IF EXISTS "shop items admin manage" ON public.shop_items;
CREATE POLICY "shop items admin manage" ON public.shop_items FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE TABLE IF NOT EXISTS public.shop_redemptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.shop_items(id) ON DELETE RESTRICT,
  cost bigint NOT NULL,
  status text NOT NULL DEFAULT 'pending', -- pending | approved | fulfilled | declined | refunded
  admin_notes text,
  fulfilled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT ON public.shop_redemptions TO authenticated;
GRANT ALL ON public.shop_redemptions TO service_role;
ALTER TABLE public.shop_redemptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "redemptions read own" ON public.shop_redemptions;
CREATE POLICY "redemptions read own" ON public.shop_redemptions FOR SELECT
  USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "redemptions admin manage" ON public.shop_redemptions;
CREATE POLICY "redemptions admin manage" ON public.shop_redemptions FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE OR REPLACE FUNCTION public.redeem_shop_item(_item_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_item public.shop_items%ROWTYPE;
  v_bal bigint;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;
  SELECT * INTO v_item FROM public.shop_items WHERE id = _item_id AND is_active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item unavailable'; END IF;
  IF v_item.stock IS NOT NULL AND v_item.stock <= 0 THEN RAISE EXCEPTION 'Out of stock'; END IF;
  SELECT token_balance INTO v_bal FROM public.profiles WHERE id = v_uid FOR UPDATE;
  IF v_bal < v_item.cost THEN RAISE EXCEPTION 'Insufficient tokens'; END IF;
  UPDATE public.profiles SET token_balance = token_balance - v_item.cost WHERE id = v_uid;
  IF v_item.stock IS NOT NULL THEN
    UPDATE public.shop_items SET stock = stock - 1 WHERE id = v_item.id;
  END IF;
  INSERT INTO public.shop_redemptions (user_id, item_id, cost)
    VALUES (v_uid, v_item.id, v_item.cost) RETURNING id INTO v_id;
  INSERT INTO public.token_transactions (user_id, delta, reason, created_at)
    VALUES (v_uid, -v_item.cost, 'shop redeem: ' || v_item.name, now());
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_shop_update_status(_redemption_id uuid, _status text, _notes text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_r public.shop_redemptions%ROWTYPE;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Forbidden'; END IF;
  IF _status NOT IN ('pending','approved','fulfilled','declined','refunded') THEN
    RAISE EXCEPTION 'Bad status';
  END IF;
  SELECT * INTO v_r FROM public.shop_redemptions WHERE id = _redemption_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not found'; END IF;

  -- Refund tokens on decline or refund (only if not already refunded)
  IF _status IN ('declined','refunded') AND v_r.status NOT IN ('declined','refunded') THEN
    UPDATE public.profiles SET token_balance = token_balance + v_r.cost WHERE id = v_r.user_id;
    INSERT INTO public.token_transactions (user_id, delta, reason, created_at)
      VALUES (v_r.user_id, v_r.cost, 'shop ' || _status || ' refund', now());
    -- Restore stock
    UPDATE public.shop_items SET stock = COALESCE(stock,0) + 1 WHERE id = v_r.item_id AND stock IS NOT NULL;
  END IF;

  UPDATE public.shop_redemptions
    SET status = _status,
        admin_notes = COALESCE(_notes, admin_notes),
        fulfilled_at = CASE WHEN _status = 'fulfilled' THEN now() ELSE fulfilled_at END,
        updated_at = now()
    WHERE id = _redemption_id;
END $$;

-- =====================================================================
-- LOTTERY
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.lottery_draws (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  number_min int NOT NULL DEFAULT 0,
  number_max int NOT NULL DEFAULT 9,
  num_picks int NOT NULL DEFAULT 1 CHECK (num_picks BETWEEN 1 AND 5),
  multiplier numeric NOT NULL DEFAULT 5,
  status text NOT NULL DEFAULT 'open', -- open | drawn | closed
  winning_numbers int[],
  draws_at timestamptz, -- when auto-draw should fire
  drawn_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.lottery_draws TO anon, authenticated;
GRANT ALL ON public.lottery_draws TO service_role;
ALTER TABLE public.lottery_draws ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "draws read all" ON public.lottery_draws;
CREATE POLICY "draws read all" ON public.lottery_draws FOR SELECT USING (true);
DROP POLICY IF EXISTS "draws admin manage" ON public.lottery_draws;
CREATE POLICY "draws admin manage" ON public.lottery_draws FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE TABLE IF NOT EXISTS public.lottery_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  draw_id uuid NOT NULL REFERENCES public.lottery_draws(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  numbers int[] NOT NULL,
  stake bigint NOT NULL CHECK (stake > 0),
  status text NOT NULL DEFAULT 'pending', -- pending | won | lost
  payout bigint DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT ON public.lottery_tickets TO authenticated;
GRANT ALL ON public.lottery_tickets TO service_role;
ALTER TABLE public.lottery_tickets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "tickets read own" ON public.lottery_tickets;
CREATE POLICY "tickets read own" ON public.lottery_tickets FOR SELECT
  USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "tickets admin manage" ON public.lottery_tickets;
CREATE POLICY "tickets admin manage" ON public.lottery_tickets FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE OR REPLACE FUNCTION public.place_lottery_ticket(_draw_id uuid, _numbers int[], _stake bigint)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_d public.lottery_draws%ROWTYPE;
  v_bal bigint;
  v_min bigint;
  v_max bigint;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;
  SELECT * INTO v_d FROM public.lottery_draws WHERE id = _draw_id FOR UPDATE;
  IF NOT FOUND OR v_d.status <> 'open' THEN RAISE EXCEPTION 'Draw not open'; END IF;
  IF array_length(_numbers, 1) IS NULL OR array_length(_numbers, 1) <> v_d.num_picks THEN
    RAISE EXCEPTION 'Pick exactly % numbers', v_d.num_picks;
  END IF;
  -- validate range + no duplicates
  IF EXISTS (SELECT 1 FROM unnest(_numbers) n WHERE n < v_d.number_min OR n > v_d.number_max) THEN
    RAISE EXCEPTION 'Number out of range';
  END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(_numbers) x) <> array_length(_numbers,1) THEN
    RAISE EXCEPTION 'No duplicate picks';
  END IF;
  SELECT lottery_min_stake, lottery_max_stake INTO v_min, v_max FROM public.app_settings WHERE id = 1;
  IF _stake < COALESCE(v_min, 100000) OR _stake > COALESCE(v_max, 50000000) THEN
    RAISE EXCEPTION 'Stake out of allowed range';
  END IF;
  SELECT token_balance INTO v_bal FROM public.profiles WHERE id = v_uid FOR UPDATE;
  IF v_bal < _stake THEN RAISE EXCEPTION 'Insufficient tokens'; END IF;
  UPDATE public.profiles SET token_balance = token_balance - _stake WHERE id = v_uid;
  INSERT INTO public.lottery_tickets (draw_id, user_id, numbers, stake)
    VALUES (_draw_id, v_uid, _numbers, _stake) RETURNING id INTO v_id;
  INSERT INTO public.token_transactions (user_id, delta, reason, created_at)
    VALUES (v_uid, -_stake, 'lottery ticket', now());
  RETURN v_id;
END $$;

-- Settle a single draw: pick winning numbers (if not yet set), pay winners
CREATE OR REPLACE FUNCTION public.settle_lottery_draw(_draw_id uuid, _winning_numbers int[] DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_d public.lottery_draws%ROWTYPE;
  v_win int[];
  v_range int;
  v_i int;
  v_pick int;
  v_t public.lottery_tickets%ROWTYPE;
  v_payout bigint;
BEGIN
  SELECT * INTO v_d FROM public.lottery_draws WHERE id = _draw_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Draw not found'; END IF;
  IF v_d.status = 'drawn' THEN RETURN; END IF;

  IF _winning_numbers IS NOT NULL THEN
    v_win := _winning_numbers;
  ELSE
    -- random distinct numbers within range
    v_win := ARRAY[]::int[];
    v_range := v_d.number_max - v_d.number_min + 1;
    IF v_range < v_d.num_picks THEN RAISE EXCEPTION 'Range too small'; END IF;
    WHILE array_length(v_win,1) IS NULL OR array_length(v_win,1) < v_d.num_picks LOOP
      v_pick := v_d.number_min + floor(random() * v_range)::int;
      IF NOT (v_pick = ANY(v_win)) THEN v_win := array_append(v_win, v_pick); END IF;
    END LOOP;
  END IF;

  UPDATE public.lottery_draws
    SET status = 'drawn', winning_numbers = v_win, drawn_at = now(), updated_at = now()
    WHERE id = _draw_id;

  -- Pay winners: all picked numbers must match (order-independent)
  FOR v_t IN SELECT * FROM public.lottery_tickets WHERE draw_id = _draw_id AND status = 'pending' LOOP
    IF (SELECT count(*) FROM unnest(v_t.numbers) n WHERE n = ANY(v_win)) = array_length(v_t.numbers, 1) THEN
      v_payout := (v_t.stake * v_d.multiplier)::bigint;
      UPDATE public.lottery_tickets SET status='won', payout=v_payout, updated_at=now() WHERE id=v_t.id;
      UPDATE public.profiles SET token_balance = token_balance + v_payout WHERE id = v_t.user_id;
      INSERT INTO public.token_transactions (user_id, delta, reason, created_at)
        VALUES (v_t.user_id, v_payout, 'lottery win', now());
    ELSE
      UPDATE public.lottery_tickets SET status='lost', updated_at=now() WHERE id=v_t.id;
    END IF;
  END LOOP;

  -- Mirror into home_lottery_results for the homepage widget
  BEGIN
    INSERT INTO public.home_lottery_results (draw_id, title, winning_numbers, drawn_at, created_at)
      VALUES (v_d.id, v_d.title, v_win, now(), now());
  EXCEPTION WHEN OTHERS THEN NULL; END;
END $$;

-- Auto-draw job: settle any draw whose deadline has passed
CREATE OR REPLACE FUNCTION public.auto_draw_lotteries()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_row public.lottery_draws%ROWTYPE;
  v_n int := 0;
BEGIN
  FOR v_row IN
    SELECT * FROM public.lottery_draws
     WHERE status = 'open'
       AND draws_at IS NOT NULL
       AND draws_at <= now()
  LOOP
    PERFORM public.settle_lottery_draw(v_row.id, NULL);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- home_lottery_results: create defensively if missing (used by homepage widget)
CREATE TABLE IF NOT EXISTS public.home_lottery_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  draw_id uuid,
  title text,
  winning_numbers int[],
  drawn_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.home_lottery_results TO anon, authenticated;
GRANT ALL ON public.home_lottery_results TO service_role;
ALTER TABLE public.home_lottery_results ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "home lotto results read" ON public.home_lottery_results;
CREATE POLICY "home lotto results read" ON public.home_lottery_results FOR SELECT USING (true);
DROP POLICY IF EXISTS "home lotto results admin" ON public.home_lottery_results;
CREATE POLICY "home lotto results admin" ON public.home_lottery_results FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- =====================================================================
-- updated_at triggers
-- =====================================================================
CREATE OR REPLACE FUNCTION public.tg_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY['faqs','polls','shop_items','shop_redemptions','lottery_draws','lottery_tickets']) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch_%1$s ON public.%1$s;', t);
    EXECUTE format('CREATE TRIGGER trg_touch_%1$s BEFORE UPDATE ON public.%1$s FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at();', t);
  END LOOP;
END $$;

-- =====================================================================
-- Cron: auto-draw every 5 minutes (catches every deadline within 5 min)
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  PERFORM cron.unschedule('auto-draw-lotteries');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT cron.schedule(
  'auto-draw-lotteries',
  '*/5 * * * *',
  $$ SELECT public.auto_draw_lotteries(); $$
);
