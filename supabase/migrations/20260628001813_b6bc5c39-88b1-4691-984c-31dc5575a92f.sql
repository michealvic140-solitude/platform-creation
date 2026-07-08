-- =========================================================
-- 1) MULTI-NUMBER LOTTERY
-- =========================================================
ALTER TABLE public.lottery_draws ADD COLUMN IF NOT EXISTS winning_numbers integer[];
ALTER TABLE public.lottery_draws ADD COLUMN IF NOT EXISTS win_count integer NOT NULL DEFAULT 10;
ALTER TABLE public.lottery_tickets ADD COLUMN IF NOT EXISTS numbers integer[];
ALTER TABLE public.lottery_tickets ALTER COLUMN number DROP NOT NULL;

-- Place a multi-number lottery ticket (pick 1..5 numbers)
CREATE OR REPLACE FUNCTION public.place_lottery_ticket_multi(_draw_id uuid, _numbers integer[], _stake bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_draw public.lottery_draws%ROWTYPE;
  v_enabled boolean;
  v_min bigint; v_max bigint;
  v_balance bigint; v_new_balance bigint; v_house bigint;
  v_ticket_id uuid;
  v_n integer; v_count integer;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT lottery_enabled, lottery_min_stake, lottery_max_stake
    INTO v_enabled, v_min, v_max FROM public.app_settings WHERE id = 1;
  IF NOT COALESCE(v_enabled, false) THEN RAISE EXCEPTION 'The lottery is currently closed'; END IF;

  SELECT * INTO v_draw FROM public.lottery_draws WHERE id = _draw_id;
  IF v_draw.id IS NULL THEN RAISE EXCEPTION 'Draw not found'; END IF;
  IF v_draw.status <> 'open' THEN RAISE EXCEPTION 'This draw is not accepting tickets'; END IF;

  -- de-duplicate picks
  SELECT array_agg(DISTINCT x) INTO _numbers FROM unnest(_numbers) x;
  v_count := COALESCE(array_length(_numbers, 1), 0);
  IF v_count < 1 OR v_count > 5 THEN RAISE EXCEPTION 'Pick between 1 and 5 numbers'; END IF;

  FOREACH v_n IN ARRAY _numbers LOOP
    IF v_n < 0 OR v_n > v_draw.number_max THEN
      RAISE EXCEPTION 'Numbers must be between 0 and %', v_draw.number_max;
    END IF;
  END LOOP;

  IF _stake < v_min THEN RAISE EXCEPTION 'Minimum stake is %', v_min; END IF;
  IF _stake > v_max THEN RAISE EXCEPTION 'Maximum stake is %', v_max; END IF;

  SELECT token_balance INTO v_balance FROM public.profiles WHERE id = v_user FOR UPDATE;
  IF v_balance < _stake THEN RAISE EXCEPTION 'Insufficient token balance'; END IF;

  UPDATE public.profiles SET token_balance = token_balance - _stake
  WHERE id = v_user RETURNING token_balance INTO v_new_balance;

  INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
  VALUES (v_user, -_stake, v_new_balance, 'lottery_stake', 'Lottery ticket: ' || array_to_string(_numbers, ','));

  UPDATE public.house_wallet SET balance = balance + _stake, total_in = total_in + _stake, updated_at = now()
    WHERE id = 1 RETURNING balance INTO v_house;
  INSERT INTO public.house_transactions (kind, amount, balance_after, user_id, reason)
  VALUES ('lottery_stake', _stake, COALESCE(v_house, 0), v_user, 'Lottery ticket');

  INSERT INTO public.lottery_tickets (draw_id, user_id, number, numbers, stake)
  VALUES (_draw_id, v_user, _numbers[1], _numbers, _stake) RETURNING id INTO v_ticket_id;

  RETURN jsonb_build_object('ok', true, 'ticket_id', v_ticket_id, 'new_balance', v_new_balance);
END;
$function$;

-- Settle the draw: pick win_count distinct winning numbers, apply payout rules
CREATE OR REPLACE FUNCTION public.draw_lottery(_draw_id uuid, _winning_number integer DEFAULT NULL::integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_draw public.lottery_draws%ROWTYPE;
  v_winning integer[];
  v_count integer;
  v_ticket record;
  v_picks integer[];
  v_matches integer;
  v_npicks integer;
  v_payout bigint;
  v_new_balance bigint;
  v_house bigint;
  v_winners integer := 0;
  v_total_payout bigint := 0;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Forbidden'; END IF;

  SELECT * INTO v_draw FROM public.lottery_draws WHERE id = _draw_id FOR UPDATE;
  IF v_draw.id IS NULL THEN RAISE EXCEPTION 'Draw not found'; END IF;
  IF v_draw.status = 'drawn' THEN RAISE EXCEPTION 'This draw is already settled'; END IF;

  v_count := LEAST(GREATEST(COALESCE(v_draw.win_count, 10), 1), v_draw.number_max + 1);

  SELECT array_agg(n) INTO v_winning FROM (
    SELECT n FROM generate_series(0, v_draw.number_max) n ORDER BY random() LIMIT v_count
  ) s;

  FOR v_ticket IN SELECT * FROM public.lottery_tickets WHERE draw_id = _draw_id AND status = 'open' LOOP
    v_picks := COALESCE(v_ticket.numbers, ARRAY[v_ticket.number]);
    v_npicks := COALESCE(array_length(v_picks, 1), 0);
    SELECT count(*) INTO v_matches FROM unnest(v_picks) x WHERE x = ANY(v_winning);

    v_payout := 0;
    IF v_npicks > 0 AND v_matches = v_npicks THEN
      v_payout := (v_ticket.stake * 2)::bigint;            -- all picks won => 2x
    ELSIF v_npicks = 5 AND v_matches = 2 THEN
      v_payout := v_ticket.stake;                          -- exactly 2 of 5 => 1x (stake back)
    END IF;

    IF v_payout > 0 THEN
      UPDATE public.lottery_tickets SET status = 'won', payout = v_payout WHERE id = v_ticket.id;
      UPDATE public.profiles SET token_balance = token_balance + v_payout
        WHERE id = v_ticket.user_id RETURNING token_balance INTO v_new_balance;
      INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
      VALUES (v_ticket.user_id, v_payout, v_new_balance, 'lottery_win', 'Lottery win');
      UPDATE public.house_wallet SET balance = balance - v_payout, total_out = total_out + v_payout, updated_at = now()
        WHERE id = 1 RETURNING balance INTO v_house;
      INSERT INTO public.house_transactions (kind, amount, balance_after, user_id, reason)
      VALUES ('lottery_payout', -v_payout, COALESCE(v_house, 0), v_ticket.user_id, 'Lottery payout');
      v_winners := v_winners + 1;
      v_total_payout := v_total_payout + v_payout;
    ELSE
      UPDATE public.lottery_tickets SET status = 'lost' WHERE id = v_ticket.id;
    END IF;
  END LOOP;

  UPDATE public.lottery_draws
    SET status = 'drawn', winning_numbers = v_winning, winning_number = v_winning[1], drawn_at = now()
    WHERE id = _draw_id;

  RETURN jsonb_build_object('ok', true, 'winning_numbers', v_winning, 'winners', v_winners, 'total_payout', v_total_payout);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.place_lottery_ticket_multi(uuid, integer[], bigint) TO authenticated;

-- =========================================================
-- 2) APP SETTINGS columns for new features
-- =========================================================
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS ticker_enabled boolean DEFAULT false;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS ticker_text text;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS ticker_speed integer DEFAULT 30;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS shop_enabled boolean DEFAULT true;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS coinflip_enabled boolean DEFAULT true;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS coinflip_min bigint DEFAULT 100000;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS coinflip_max bigint DEFAULT 50000000;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS coinflip_payout numeric DEFAULT 1.95;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS wheel_enabled boolean DEFAULT true;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS wheel_min bigint DEFAULT 100000;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS wheel_max bigint DEFAULT 50000000;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS scratch_enabled boolean DEFAULT true;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS scratch_price bigint DEFAULT 500000;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS trivia_enabled boolean DEFAULT true;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS polls_enabled boolean DEFAULT true;

-- =========================================================
-- 3) UTILITY FEATURE TABLES
-- =========================================================
-- FAQ / Help Center
CREATE TABLE IF NOT EXISTS public.faqs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question text NOT NULL,
  answer text NOT NULL,
  category text,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.faqs TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.faqs TO authenticated;
GRANT ALL ON public.faqs TO service_role;
ALTER TABLE public.faqs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "faqs public read active" ON public.faqs FOR SELECT USING (is_active OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "faqs admin manage" ON public.faqs FOR ALL TO authenticated USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

-- Feedback / Suggestion box
CREATE TABLE IF NOT EXISTS public.feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  category text NOT NULL DEFAULT 'general',
  message text NOT NULL,
  status text NOT NULL DEFAULT 'open',
  admin_reply text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.feedback TO authenticated;
GRANT ALL ON public.feedback TO service_role;
ALTER TABLE public.feedback ENABLE ROW LEVEL SECURITY;
CREATE POLICY "feedback own select" ON public.feedback FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "feedback own insert" ON public.feedback FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "feedback admin update" ON public.feedback FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "feedback admin delete" ON public.feedback FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- Rewards Shop
CREATE TABLE IF NOT EXISTS public.shop_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  image_url text,
  cost bigint NOT NULL DEFAULT 0,
  stock integer,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.shop_items TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.shop_items TO authenticated;
GRANT ALL ON public.shop_items TO service_role;
ALTER TABLE public.shop_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shop items public read" ON public.shop_items FOR SELECT USING (is_active OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "shop items admin manage" ON public.shop_items FOR ALL TO authenticated USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE TABLE IF NOT EXISTS public.shop_redemptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.shop_items(id) ON DELETE CASCADE,
  cost bigint NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shop_redemptions TO authenticated;
GRANT ALL ON public.shop_redemptions TO service_role;
ALTER TABLE public.shop_redemptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shop redemptions own select" ON public.shop_redemptions FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "shop redemptions admin update" ON public.shop_redemptions FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE OR REPLACE FUNCTION public.redeem_shop_item(_item_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_item public.shop_items%ROWTYPE;
  v_bal bigint; v_new bigint; v_rid uuid;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_item FROM public.shop_items WHERE id = _item_id FOR UPDATE;
  IF v_item.id IS NULL OR NOT v_item.is_active THEN RAISE EXCEPTION 'Item unavailable'; END IF;
  IF v_item.stock IS NOT NULL AND v_item.stock <= 0 THEN RAISE EXCEPTION 'Out of stock'; END IF;
  SELECT token_balance INTO v_bal FROM public.profiles WHERE id = v_user FOR UPDATE;
  IF v_bal < v_item.cost THEN RAISE EXCEPTION 'Insufficient token balance'; END IF;
  UPDATE public.profiles SET token_balance = token_balance - v_item.cost WHERE id = v_user RETURNING token_balance INTO v_new;
  INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
  VALUES (v_user, -v_item.cost, v_new, 'shop_redeem', 'Reward shop: ' || v_item.name);
  IF v_item.stock IS NOT NULL THEN UPDATE public.shop_items SET stock = stock - 1 WHERE id = _item_id; END IF;
  INSERT INTO public.shop_redemptions (user_id, item_id, cost) VALUES (v_user, _item_id, v_item.cost) RETURNING id INTO v_rid;
  RETURN jsonb_build_object('ok', true, 'redemption_id', v_rid, 'new_balance', v_new);
END; $function$;
GRANT EXECUTE ON FUNCTION public.redeem_shop_item(uuid) TO authenticated;

-- Saved Beneficiaries (transfer recipients)
CREATE TABLE IF NOT EXISTS public.beneficiaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label text NOT NULL,
  beneficiary_special_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.beneficiaries TO authenticated;
GRANT ALL ON public.beneficiaries TO service_role;
ALTER TABLE public.beneficiaries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "beneficiaries own all" ON public.beneficiaries FOR ALL TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(),'admin')) WITH CHECK (auth.uid() = user_id);

-- =========================================================
-- 4) ENTERTAINMENT TABLES
-- =========================================================
-- Generic instant-game plays
CREATE TABLE IF NOT EXISTS public.casino_plays (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game text NOT NULL,
  stake bigint NOT NULL DEFAULT 0,
  payout bigint NOT NULL DEFAULT 0,
  outcome text,
  detail jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT ON public.casino_plays TO authenticated;
GRANT ALL ON public.casino_plays TO service_role;
ALTER TABLE public.casino_plays ENABLE ROW LEVEL SECURITY;
CREATE POLICY "casino plays own select" ON public.casino_plays FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(),'admin'));

-- shared settle helper
CREATE OR REPLACE FUNCTION public._casino_settle(_user uuid, _game text, _stake bigint, _payout bigint, _outcome text, _detail jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_bal bigint; v_mid bigint; v_new bigint; v_house bigint;
BEGIN
  SELECT token_balance INTO v_bal FROM public.profiles WHERE id = _user FOR UPDATE;
  IF v_bal < _stake THEN RAISE EXCEPTION 'Insufficient token balance'; END IF;
  v_mid := v_bal - _stake;
  UPDATE public.profiles SET token_balance = v_mid + _payout WHERE id = _user RETURNING token_balance INTO v_new;
  INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
  VALUES (_user, -_stake, v_mid, _game || '_stake', _game || ' stake');
  IF _payout > 0 THEN
    INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
    VALUES (_user, _payout, v_new, _game || '_win', _game || ' win');
  END IF;
  UPDATE public.house_wallet SET balance = balance + _stake - _payout, total_in = total_in + _stake, total_out = total_out + _payout, updated_at = now()
    WHERE id = 1 RETURNING balance INTO v_house;
  INSERT INTO public.house_transactions (kind, amount, balance_after, user_id, reason)
  VALUES (_game, _stake - _payout, COALESCE(v_house,0), _user, _game || ' play');
  INSERT INTO public.casino_plays (user_id, game, stake, payout, outcome, detail)
  VALUES (_user, _game, _stake, _payout, _outcome, _detail);
  RETURN jsonb_build_object('ok', true, 'new_balance', v_new, 'payout', _payout, 'outcome', _outcome);
END; $function$;

-- Coin flip
CREATE OR REPLACE FUNCTION public.play_coinflip(_choice text, _stake bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_user uuid := auth.uid(); v_en boolean; v_min bigint; v_max bigint; v_mult numeric; v_result text; v_win boolean; v_payout bigint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF _choice NOT IN ('heads','tails') THEN RAISE EXCEPTION 'Invalid choice'; END IF;
  SELECT coinflip_enabled, coinflip_min, coinflip_max, coinflip_payout INTO v_en, v_min, v_max, v_mult FROM public.app_settings WHERE id=1;
  IF NOT COALESCE(v_en,false) THEN RAISE EXCEPTION 'Coin flip is currently closed'; END IF;
  IF _stake < v_min THEN RAISE EXCEPTION 'Minimum stake is %', v_min; END IF;
  IF _stake > v_max THEN RAISE EXCEPTION 'Maximum stake is %', v_max; END IF;
  v_result := CASE WHEN random() < 0.5 THEN 'heads' ELSE 'tails' END;
  v_win := v_result = _choice;
  v_payout := CASE WHEN v_win THEN floor(_stake * COALESCE(v_mult,1.95))::bigint ELSE 0 END;
  RETURN public._casino_settle(v_user, 'coinflip', _stake, v_payout, v_result, jsonb_build_object('choice', _choice, 'result', v_result, 'win', v_win));
END; $function$;
GRANT EXECUTE ON FUNCTION public.play_coinflip(text, bigint) TO authenticated;

-- Wheel of fortune
CREATE OR REPLACE FUNCTION public.play_wheel(_stake bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_user uuid := auth.uid(); v_en boolean; v_min bigint; v_max bigint;
  v_segments numeric[] := ARRAY[0,0,1.5,0,2,0,1.2,0,3,0,5,0.5]; v_idx int; v_mult numeric; v_payout bigint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT wheel_enabled, wheel_min, wheel_max INTO v_en, v_min, v_max FROM public.app_settings WHERE id=1;
  IF NOT COALESCE(v_en,false) THEN RAISE EXCEPTION 'Wheel is currently closed'; END IF;
  IF _stake < v_min THEN RAISE EXCEPTION 'Minimum stake is %', v_min; END IF;
  IF _stake > v_max THEN RAISE EXCEPTION 'Maximum stake is %', v_max; END IF;
  v_idx := floor(random() * array_length(v_segments,1))::int + 1;
  v_mult := v_segments[v_idx];
  v_payout := floor(_stake * v_mult)::bigint;
  RETURN public._casino_settle(v_user, 'wheel', _stake, v_payout, v_mult::text || 'x', jsonb_build_object('segment', v_idx-1, 'multiplier', v_mult));
END; $function$;
GRANT EXECUTE ON FUNCTION public.play_wheel(bigint) TO authenticated;

-- Scratch card
CREATE OR REPLACE FUNCTION public.play_scratch()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_user uuid := auth.uid(); v_en boolean; v_price bigint; r numeric; v_mult numeric; v_payout bigint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT scratch_enabled, scratch_price INTO v_en, v_price FROM public.app_settings WHERE id=1;
  IF NOT COALESCE(v_en,false) THEN RAISE EXCEPTION 'Scratch cards are currently closed'; END IF;
  r := random();
  v_mult := CASE
    WHEN r < 0.55 THEN 0
    WHEN r < 0.80 THEN 1
    WHEN r < 0.93 THEN 2
    WHEN r < 0.985 THEN 5
    ELSE 10 END;
  v_payout := floor(v_price * v_mult)::bigint;
  RETURN public._casino_settle(v_user, 'scratch', v_price, v_payout, v_mult::text || 'x', jsonb_build_object('multiplier', v_mult));
END; $function$;
GRANT EXECUTE ON FUNCTION public.play_scratch() TO authenticated;

-- Trivia / Quiz
CREATE TABLE IF NOT EXISTS public.trivia_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question text NOT NULL,
  options jsonb NOT NULL DEFAULT '[]'::jsonb,
  correct_index integer NOT NULL DEFAULT 0,
  reward bigint NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.trivia_questions TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.trivia_questions TO authenticated;
GRANT ALL ON public.trivia_questions TO service_role;
ALTER TABLE public.trivia_questions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "trivia public read" ON public.trivia_questions FOR SELECT USING (is_active OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "trivia admin manage" ON public.trivia_questions FOR ALL TO authenticated USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE TABLE IF NOT EXISTS public.trivia_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  question_id uuid NOT NULL REFERENCES public.trivia_questions(id) ON DELETE CASCADE,
  selected_index integer NOT NULL,
  is_correct boolean NOT NULL DEFAULT false,
  reward bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, question_id)
);
GRANT SELECT, INSERT ON public.trivia_attempts TO authenticated;
GRANT ALL ON public.trivia_attempts TO service_role;
ALTER TABLE public.trivia_attempts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "trivia attempts own select" ON public.trivia_attempts FOR SELECT TO authenticated USING (auth.uid() = user_id OR public.has_role(auth.uid(),'admin'));

CREATE OR REPLACE FUNCTION public.answer_trivia(_question_id uuid, _selected_index integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_user uuid := auth.uid(); v_q public.trivia_questions%ROWTYPE; v_en boolean; v_correct boolean; v_reward bigint := 0; v_new bigint; v_house bigint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT trivia_enabled INTO v_en FROM public.app_settings WHERE id=1;
  IF NOT COALESCE(v_en,false) THEN RAISE EXCEPTION 'Trivia is currently closed'; END IF;
  SELECT * INTO v_q FROM public.trivia_questions WHERE id=_question_id;
  IF v_q.id IS NULL OR NOT v_q.is_active THEN RAISE EXCEPTION 'Question unavailable'; END IF;
  IF EXISTS (SELECT 1 FROM public.trivia_attempts WHERE user_id=v_user AND question_id=_question_id) THEN
    RAISE EXCEPTION 'You already answered this question';
  END IF;
  v_correct := _selected_index = v_q.correct_index;
  IF v_correct THEN
    v_reward := v_q.reward;
    UPDATE public.profiles SET token_balance = token_balance + v_reward WHERE id=v_user RETURNING token_balance INTO v_new;
    IF v_reward > 0 THEN
      INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
      VALUES (v_user, v_reward, v_new, 'trivia_reward', 'Trivia reward');
      UPDATE public.house_wallet SET balance = balance - v_reward, total_out = total_out + v_reward, updated_at = now() WHERE id=1 RETURNING balance INTO v_house;
      INSERT INTO public.house_transactions (kind, amount, balance_after, user_id, reason) VALUES ('trivia_reward', -v_reward, COALESCE(v_house,0), v_user, 'Trivia reward');
    END IF;
  END IF;
  INSERT INTO public.trivia_attempts (user_id, question_id, selected_index, is_correct, reward)
  VALUES (v_user, _question_id, _selected_index, v_correct, v_reward);
  RETURN jsonb_build_object('ok', true, 'correct', v_correct, 'correct_index', v_q.correct_index, 'reward', v_reward);
END; $function$;
GRANT EXECUTE ON FUNCTION public.answer_trivia(uuid, integer) TO authenticated;

-- Prediction polls
CREATE TABLE IF NOT EXISTS public.polls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question text NOT NULL,
  options jsonb NOT NULL DEFAULT '[]'::jsonb,
  closes_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.polls TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.polls TO authenticated;
GRANT ALL ON public.polls TO service_role;
ALTER TABLE public.polls ENABLE ROW LEVEL SECURITY;
CREATE POLICY "polls public read" ON public.polls FOR SELECT USING (is_active OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "polls admin manage" ON public.polls FOR ALL TO authenticated USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE TABLE IF NOT EXISTS public.poll_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.polls(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  selected_index integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (poll_id, user_id)
);
GRANT SELECT, INSERT ON public.poll_votes TO authenticated;
GRANT ALL ON public.poll_votes TO service_role;
ALTER TABLE public.poll_votes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "poll votes read" ON public.poll_votes FOR SELECT TO authenticated USING (true);
CREATE POLICY "poll votes own insert" ON public.poll_votes FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- updated_at trigger reuse
CREATE OR REPLACE FUNCTION public.update_updated_at_column() RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql SET search_path = public;
DROP TRIGGER IF EXISTS faqs_updated_at ON public.faqs;
CREATE TRIGGER faqs_updated_at BEFORE UPDATE ON public.faqs FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS feedback_updated_at ON public.feedback;
CREATE TRIGGER feedback_updated_at BEFORE UPDATE ON public.feedback FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS shop_items_updated_at ON public.shop_items;
CREATE TRIGGER shop_items_updated_at BEFORE UPDATE ON public.shop_items FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();