-- Compatibility helper (matches naming used in repo migrations)
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

-- === 20260709015203 ===
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS discord_support_url text;
ALTER TABLE public.lottery_draws ADD COLUMN IF NOT EXISTS picks_count integer NOT NULL DEFAULT 1;

DROP POLICY IF EXISTS "shop redemptions admin select" ON public.shop_redemptions;
CREATE POLICY "shop redemptions admin select" ON public.shop_redemptions
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "poll votes admin delete" ON public.poll_votes;
CREATE POLICY "poll votes admin delete" ON public.poll_votes
  FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

CREATE OR REPLACE FUNCTION public.refund_shop_redemption(_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_red public.shop_redemptions%ROWTYPE; v_new bigint; v_name text;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO v_red FROM public.shop_redemptions WHERE id = _id FOR UPDATE;
  IF v_red.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF v_red.status = 'refunded' THEN RAISE EXCEPTION 'Already refunded'; END IF;
  UPDATE public.profiles SET token_balance = token_balance + v_red.cost
    WHERE id = v_red.user_id RETURNING token_balance INTO v_new;
  SELECT name INTO v_name FROM public.shop_items WHERE id = v_red.item_id;
  INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
    VALUES (v_red.user_id, v_red.cost, v_new, 'shop_refund', 'Refund: ' || COALESCE(v_name, 'shop item'));
  UPDATE public.shop_items SET stock = stock + 1 WHERE id = v_red.item_id AND stock IS NOT NULL;
  UPDATE public.shop_redemptions SET status = 'refunded' WHERE id = _id;
  RETURN jsonb_build_object('ok', true, 'new_balance', v_new);
END; $function$;
GRANT EXECUTE ON FUNCTION public.refund_shop_redemption(uuid) TO authenticated;

-- === 20260710073606 ===
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS featured_bg_url text,
  ADD COLUMN IF NOT EXISTS featured_bg_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS featured_bg_position text DEFAULT 'center';

-- === 20260710080038 : news table & lottery multi-pick ===
CREATE TABLE IF NOT EXISTS public.news (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  title text NOT NULL, body text, image_url text, link_url text,
  is_active boolean NOT NULL DEFAULT true, sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.news TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.news TO authenticated;
GRANT ALL ON public.news TO service_role;
ALTER TABLE public.news ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "news public read" ON public.news;
CREATE POLICY "news public read" ON public.news FOR SELECT USING (true);
DROP POLICY IF EXISTS "admins manage news" ON public.news;
CREATE POLICY "admins manage news" ON public.news FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
DROP TRIGGER IF EXISTS update_news_updated_at ON public.news;
CREATE TRIGGER update_news_updated_at BEFORE UPDATE ON public.news
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DO $$ BEGIN
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.news; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;

CREATE OR REPLACE FUNCTION public.place_lottery_ticket_multi(_draw_id uuid, _numbers integer[], _stake bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user uuid := auth.uid(); v_draw public.lottery_draws%ROWTYPE;
  v_enabled boolean; v_min bigint; v_max bigint;
  v_balance bigint; v_new_balance bigint; v_house bigint; v_ticket_id uuid;
  v_n integer; v_count integer;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT lottery_enabled, lottery_min_stake, lottery_max_stake
    INTO v_enabled, v_min, v_max FROM public.app_settings WHERE id = 1;
  IF NOT COALESCE(v_enabled, false) THEN RAISE EXCEPTION 'The lottery is currently closed'; END IF;
  SELECT * INTO v_draw FROM public.lottery_draws WHERE id = _draw_id;
  IF v_draw.id IS NULL THEN RAISE EXCEPTION 'Draw not found'; END IF;
  IF v_draw.status <> 'open' THEN RAISE EXCEPTION 'This draw is not accepting tickets'; END IF;
  SELECT array_agg(DISTINCT x) INTO _numbers FROM unnest(_numbers) x;
  v_count := COALESCE(array_length(_numbers, 1), 0);
  IF v_count < 1 OR v_count > 10 THEN RAISE EXCEPTION 'Pick between 1 and 10 numbers'; END IF;
  IF v_count <> COALESCE(v_draw.picks_count, 1) THEN
    RAISE EXCEPTION 'Pick exactly % number(s) for this draw', COALESCE(v_draw.picks_count, 1);
  END IF;
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
END; $function$;

CREATE OR REPLACE FUNCTION public._settle_lottery_draw(_draw_id uuid, _winning integer[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_draw public.lottery_draws%ROWTYPE; v_ticket record;
  v_picks integer[]; v_matches integer; v_npicks integer;
  v_payout bigint; v_new_balance bigint; v_house bigint;
  v_winners integer := 0; v_total_payout bigint := 0;
BEGIN
  SELECT * INTO v_draw FROM public.lottery_draws WHERE id = _draw_id FOR UPDATE;
  IF v_draw.id IS NULL THEN RAISE EXCEPTION 'Draw not found'; END IF;
  IF v_draw.status = 'drawn' THEN RAISE EXCEPTION 'This draw is already settled'; END IF;
  FOR v_ticket IN SELECT * FROM public.lottery_tickets WHERE draw_id = _draw_id AND status = 'open' LOOP
    v_picks := COALESCE(v_ticket.numbers, ARRAY[v_ticket.number]);
    v_npicks := COALESCE(array_length(v_picks, 1), 0);
    SELECT count(*) INTO v_matches FROM unnest(v_picks) x WHERE x = ANY(_winning);
    v_payout := 0;
    IF v_npicks > 0 AND v_matches = v_npicks THEN
      v_payout := (v_ticket.stake * v_draw.multiplier)::bigint;
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
      v_winners := v_winners + 1; v_total_payout := v_total_payout + v_payout;
    ELSE
      UPDATE public.lottery_tickets SET status = 'lost' WHERE id = v_ticket.id;
    END IF;
  END LOOP;
  UPDATE public.lottery_draws
    SET status = 'drawn', winning_numbers = _winning, winning_number = _winning[1], drawn_at = now()
    WHERE id = _draw_id;
  RETURN jsonb_build_object('ok', true, 'winning_numbers', _winning, 'winners', v_winners, 'total_payout', v_total_payout);
END; $function$;

CREATE OR REPLACE FUNCTION public.draw_lottery(_draw_id uuid, _winning_number integer DEFAULT NULL::integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_draw public.lottery_draws%ROWTYPE; v_winning integer[]; v_count integer;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Forbidden'; END IF;
  SELECT * INTO v_draw FROM public.lottery_draws WHERE id = _draw_id;
  IF v_draw.id IS NULL THEN RAISE EXCEPTION 'Draw not found'; END IF;
  v_count := LEAST(GREATEST(COALESCE(v_draw.win_count, 10), 10), v_draw.number_max + 1);
  IF _winning_number IS NOT NULL THEN
    v_winning := ARRAY[_winning_number];
    SELECT v_winning || COALESCE(array_agg(n), ARRAY[]::integer[]) INTO v_winning FROM (
      SELECT n FROM generate_series(0, v_draw.number_max) n
      WHERE n <> _winning_number ORDER BY random() LIMIT GREATEST(v_count - 1, 0)
    ) s;
  ELSE
    SELECT array_agg(n) INTO v_winning FROM (
      SELECT n FROM generate_series(0, v_draw.number_max) n ORDER BY random() LIMIT v_count
    ) s;
  END IF;
  RETURN public._settle_lottery_draw(_draw_id, v_winning);
END; $function$;

CREATE OR REPLACE FUNCTION public.auto_draw_due_lotteries()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_draw record; v_winning integer[]; v_count integer; v_done integer := 0;
BEGIN
  FOR v_draw IN SELECT * FROM public.lottery_draws
    WHERE status = 'open' AND (COALESCE(draw_at, created_at + interval '30 minutes') <= now())
  LOOP
    v_count := LEAST(GREATEST(COALESCE(v_draw.win_count, 10), 10), v_draw.number_max + 1);
    SELECT array_agg(n) INTO v_winning FROM (
      SELECT n FROM generate_series(0, v_draw.number_max) n ORDER BY random() LIMIT v_count
    ) s;
    PERFORM public._settle_lottery_draw(v_draw.id, v_winning);
    v_done := v_done + 1;
  END LOOP;
  RETURN v_done;
END; $function$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'auto-draw-lotteries') THEN
    PERFORM cron.unschedule('auto-draw-lotteries');
  END IF;
  PERFORM cron.schedule('auto-draw-lotteries', '*/5 * * * *', $$ SELECT public.auto_draw_due_lotteries(); $$);
END; $cron$;

-- === 20260710080057 ===
REVOKE ALL ON FUNCTION public._settle_lottery_draw(uuid, integer[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auto_draw_due_lotteries() FROM PUBLIC, anon, authenticated;

-- === 20260711003527 ===
ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS featured_image_url text,
  ADD COLUMN IF NOT EXISTS featured_image_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS featured_image_position text DEFAULT 'center';

-- === 20260712090851 : hardened real-ticket placement ===
CREATE OR REPLACE FUNCTION public.place_real_ticket(_selections jsonb, _stake bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  uid uuid := auth.uid(); p record; cfg record;
  total_odds numeric := 1; payout bigint; bet_id uuid; tracking text; new_bal bigint;
  s jsonb; o record; mk record; m record;
  sel_count int; cap bigint; is_future_ticket boolean := true;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  sel_count := jsonb_array_length(_selections);
  IF sel_count IS NULL OR sel_count = 0 THEN RAISE EXCEPTION 'No selections'; END IF;
  SELECT * INTO p FROM public.profiles WHERE id = uid FOR UPDATE;
  IF p.is_banned OR p.is_restricted THEN RAISE EXCEPTION 'Account restricted'; END IF;
  SELECT min_stake, max_payout, max_selections_per_ticket,
         futures_min_stake, futures_max_payout, futures_max_selections
    INTO cfg FROM public.app_settings WHERE id = 1;
  FOR s IN SELECT * FROM jsonb_array_elements(_selections) LOOP
    SELECT * INTO o FROM public.odds WHERE id = (s->>'odd_id')::uuid;
    IF o IS NULL THEN RAISE EXCEPTION 'Bad selection'; END IF;
    SELECT * INTO mk FROM public.markets WHERE id = o.market_id;
    SELECT * INTO m FROM public.matches WHERE id = mk.match_id;
    IF m.is_virtual THEN RAISE EXCEPTION 'Virtual picks must be placed on the virtual slip'; END IF;
    IF COALESCE(m.match_kind, 'normal') <> 'future' THEN is_future_ticket := false; END IF;
    IF m.status <> 'scheduled' OR (m.lock_time IS NOT NULL AND m.lock_time <= now()) OR NOT mk.is_open THEN
      RAISE EXCEPTION 'Betting is closed: %', m.name;
    END IF;
    total_odds := total_odds * o.value;
  END LOOP;
  IF is_future_ticket THEN
    IF _stake < COALESCE(cfg.futures_min_stake, 1) THEN RAISE EXCEPTION 'Stake below minimum'; END IF;
    IF sel_count > COALESCE(cfg.futures_max_selections, 1) THEN RAISE EXCEPTION 'Too many selections'; END IF;
    cap := COALESCE(NULLIF(cfg.futures_max_payout, 0), 100000000);
  ELSE
    IF sel_count < 2 THEN RAISE EXCEPTION 'Minimum 2 selections required'; END IF;
    IF _stake < COALESCE(cfg.min_stake, 2000000) THEN RAISE EXCEPTION 'Stake below minimum'; END IF;
    IF sel_count > COALESCE(cfg.max_selections_per_ticket, 20) THEN RAISE EXCEPTION 'Too many selections'; END IF;
    cap := COALESCE(NULLIF(cfg.max_payout, 0), 100000000);
  END IF;
  IF p.token_balance < _stake THEN RAISE EXCEPTION 'Insufficient balance'; END IF;
  payout := LEAST((total_odds * _stake)::bigint, cap);
  INSERT INTO public.bets(user_id, stake, total_odds, potential_payout, status)
    VALUES (uid, _stake, total_odds, payout, 'open') RETURNING id, tracking_id INTO bet_id, tracking;
  FOR s IN SELECT * FROM jsonb_array_elements(_selections) LOOP
    SELECT * INTO o FROM public.odds WHERE id = (s->>'odd_id')::uuid;
    SELECT * INTO mk FROM public.markets WHERE id = o.market_id;
    INSERT INTO public.bet_selections(bet_id, match_id, market_id, odd_id, locked_odds, selection_label)
      VALUES (bet_id, mk.match_id, mk.id, o.id, o.value, o.label);
  END LOOP;
  UPDATE public.profiles SET token_balance = token_balance - _stake WHERE id = uid RETURNING token_balance INTO new_bal;
  INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (uid, 'Bet placed', 'Ticket ' || tracking || ' - ' || _stake || ' tokens staked.', '/ticket/' || bet_id);
  RETURN jsonb_build_object('bet_id', bet_id, 'tracking_id', tracking, 'stake', _stake, 'payout', payout, 'balance', new_bal, 'max_payout_cap', cap);
END; $$;
REVOKE ALL ON FUNCTION public.place_real_ticket(jsonb, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.place_real_ticket(jsonb, bigint) TO authenticated;

-- === 20260713002045 : profile-protection fix + admin notification triggers ===
CREATE OR REPLACE FUNCTION public.protect_profile_sensitive_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user NOT IN ('authenticated', 'anon')
     OR auth.role() = 'service_role'
     OR public.is_admin(auth.uid()) THEN
    RETURN NEW;
  END IF;
  NEW.token_balance := OLD.token_balance;
  NEW.is_banned := OLD.is_banned;
  NEW.ban_reason := OLD.ban_reason;
  NEW.is_muted := OLD.is_muted;
  NEW.mute_reason := OLD.mute_reason;
  NEW.is_restricted := OLD.is_restricted;
  NEW.restrict_reason := OLD.restrict_reason;
  NEW.vip_tier := OLD.vip_tier;
  NEW.xp := OLD.xp;
  NEW.streak_days := OLD.streak_days;
  NEW.longest_streak := OLD.longest_streak;
  NEW.last_login_date := OLD.last_login_date;
  NEW.referral_code := OLD.referral_code;
  NEW.referred_by := OLD.referred_by;
  NEW.emblem_status := OLD.emblem_status;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION public.notify_admins(_title text, _body text, _link text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.notifications(user_id, title, body, link)
  SELECT DISTINCT ur.user_id, _title, _body, COALESCE(_link, '/admin')
  FROM public.user_roles ur WHERE ur.role = 'admin';
END; $function$;

CREATE OR REPLACE FUNCTION public.display_name_for(_uid uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT COALESCE(NULLIF(TRIM(full_name), ''), 'A user') FROM public.profiles WHERE id = _uid
$function$;

CREATE OR REPLACE FUNCTION public.notify_admins_bet_placed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$ BEGIN
  PERFORM public.notify_admins('New bet placed',
    public.display_name_for(NEW.user_id) || ' staked ' || NEW.stake::text ||
      ' tokens · ' || COALESCE(NEW.tracking_id, 'ticket'),
    '/ticket/' || NEW.id::text);
  RETURN NEW; END; $function$;
DROP TRIGGER IF EXISTS trg_notify_admins_bet ON public.bets;
CREATE TRIGGER trg_notify_admins_bet AFTER INSERT ON public.bets
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_bet_placed();

CREATE OR REPLACE FUNCTION public.notify_admins_token_request()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$ BEGIN
  PERFORM public.notify_admins('New token request',
    public.display_name_for(NEW.user_id) || ' requested ' || NEW.amount::text || ' tokens.', '/admin');
  RETURN NEW; END; $function$;
DROP TRIGGER IF EXISTS trg_notify_admins_token_request ON public.token_requests;
CREATE TRIGGER trg_notify_admins_token_request AFTER INSERT ON public.token_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_token_request();

CREATE OR REPLACE FUNCTION public.notify_admins_support_ticket()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$ BEGIN
  PERFORM public.notify_admins('New support ticket',
    public.display_name_for(NEW.user_id) || ': ' || COALESCE(NEW.subject, 'New ticket'), '/admin');
  RETURN NEW; END; $function$;
DROP TRIGGER IF EXISTS trg_notify_admins_support_ticket ON public.support_tickets;
CREATE TRIGGER trg_notify_admins_support_ticket AFTER INSERT ON public.support_tickets
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_support_ticket();

CREATE OR REPLACE FUNCTION public.notify_admins_withdrawal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$ BEGIN
  PERFORM public.notify_admins('New withdrawal request',
    public.display_name_for(NEW.user_id) || ' requested ' || NEW.amount::text || ' tokens.', '/admin');
  RETURN NEW; END; $function$;
DROP TRIGGER IF EXISTS trg_notify_admins_withdrawal ON public.withdrawal_requests;
CREATE TRIGGER trg_notify_admins_withdrawal AFTER INSERT ON public.withdrawal_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_withdrawal();

CREATE OR REPLACE FUNCTION public.notify_admins_promo_request()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$ BEGIN
  PERFORM public.notify_admins('New promo code request',
    public.display_name_for(NEW.user_id) || ' requested a promo code (' || COALESCE(NEW.amount, 0)::text || ' tokens).', '/admin');
  RETURN NEW; END; $function$;
DROP TRIGGER IF EXISTS trg_notify_admins_promo_request ON public.promo_code_requests;
CREATE TRIGGER trg_notify_admins_promo_request AFTER INSERT ON public.promo_code_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_promo_request();

CREATE OR REPLACE FUNCTION public.notify_admins_virtual_payout()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$ BEGIN
  PERFORM public.notify_admins('Virtual payout to approve',
    public.display_name_for(NEW.user_id) || ' won ' || NEW.amount::text || ' tokens on a virtual ticket.', '/admin');
  RETURN NEW; END; $function$;
DROP TRIGGER IF EXISTS trg_notify_admins_virtual_payout ON public.virtual_payout_requests;
CREATE TRIGGER trg_notify_admins_virtual_payout AFTER INSERT ON public.virtual_payout_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_virtual_payout();

-- === 20260713002102 ===
REVOKE EXECUTE ON FUNCTION public.notify_admins(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.display_name_for(uuid) FROM PUBLIC, anon, authenticated;

-- === 20260714115510 : championship base ===
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS virtual_championship_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'legacy',
  ADD COLUMN IF NOT EXISTS starts_at timestamptz,
  ADD COLUMN IF NOT EXISTS current_stage text,
  ADD COLUMN IF NOT EXISTS stage_gap_seconds integer NOT NULL DEFAULT 20,
  ADD COLUMN IF NOT EXISTS bracket_size integer NOT NULL DEFAULT 16;
CREATE INDEX IF NOT EXISTS idx_tournaments_kind_status
  ON public.tournaments (kind, status, starts_at);