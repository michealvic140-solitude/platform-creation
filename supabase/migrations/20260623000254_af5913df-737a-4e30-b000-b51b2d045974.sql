-- ============ PHASE 3: LOTTERY SYSTEM ============

-- Admin-configurable lottery settings on app_settings
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS lottery_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS lottery_min_stake bigint NOT NULL DEFAULT 100000,
  ADD COLUMN IF NOT EXISTS lottery_max_stake bigint NOT NULL DEFAULT 50000000,
  ADD COLUMN IF NOT EXISTS lottery_intro text;

-- A lottery draw / round
CREATE TABLE IF NOT EXISTS public.lottery_draws (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  title text NOT NULL DEFAULT 'Lucky Numbers Draw',
  number_max integer NOT NULL DEFAULT 9,
  multiplier numeric NOT NULL DEFAULT 2,
  status text NOT NULL DEFAULT 'open',
  winning_number integer,
  draw_at timestamp with time zone,
  drawn_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

GRANT SELECT ON public.lottery_draws TO anon, authenticated;
GRANT ALL ON public.lottery_draws TO service_role;
ALTER TABLE public.lottery_draws ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view lottery draws"
  ON public.lottery_draws FOR SELECT
  USING (true);

CREATE POLICY "Admins manage lottery draws"
  ON public.lottery_draws FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Lottery tickets purchased by users
CREATE TABLE IF NOT EXISTS public.lottery_tickets (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  draw_id uuid NOT NULL REFERENCES public.lottery_draws(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  number integer NOT NULL,
  stake bigint NOT NULL,
  status text NOT NULL DEFAULT 'open',
  payout bigint NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON public.lottery_tickets TO authenticated;
GRANT ALL ON public.lottery_tickets TO service_role;
ALTER TABLE public.lottery_tickets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users view own lottery tickets"
  ON public.lottery_tickets FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Admins manage lottery tickets"
  ON public.lottery_tickets FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE INDEX IF NOT EXISTS idx_lottery_tickets_draw ON public.lottery_tickets (draw_id);
CREATE INDEX IF NOT EXISTS idx_lottery_tickets_user ON public.lottery_tickets (user_id);

-- updated_at trigger for draws
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

DROP TRIGGER IF EXISTS update_lottery_draws_updated_at ON public.lottery_draws;
CREATE TRIGGER update_lottery_draws_updated_at
  BEFORE UPDATE ON public.lottery_draws
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Place a lottery ticket: validates, deducts tokens, credits house wallet
CREATE OR REPLACE FUNCTION public.place_lottery_ticket(_draw_id uuid, _number integer, _stake bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_draw public.lottery_draws%ROWTYPE;
  v_enabled boolean;
  v_min bigint;
  v_max bigint;
  v_balance bigint;
  v_new_balance bigint;
  v_house bigint;
  v_ticket_id uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT lottery_enabled, lottery_min_stake, lottery_max_stake
    INTO v_enabled, v_min, v_max
  FROM public.app_settings WHERE id = 1;

  IF NOT COALESCE(v_enabled, false) THEN
    RAISE EXCEPTION 'The lottery is currently closed';
  END IF;

  SELECT * INTO v_draw FROM public.lottery_draws WHERE id = _draw_id;
  IF v_draw.id IS NULL THEN
    RAISE EXCEPTION 'Draw not found';
  END IF;
  IF v_draw.status <> 'open' THEN
    RAISE EXCEPTION 'This draw is not accepting tickets';
  END IF;
  IF _number < 0 OR _number > v_draw.number_max THEN
    RAISE EXCEPTION 'Pick a number between 0 and %', v_draw.number_max;
  END IF;
  IF _stake < v_min THEN
    RAISE EXCEPTION 'Minimum stake is %', v_min;
  END IF;
  IF _stake > v_max THEN
    RAISE EXCEPTION 'Maximum stake is %', v_max;
  END IF;

  SELECT token_balance INTO v_balance FROM public.profiles WHERE id = v_user FOR UPDATE;
  IF v_balance < _stake THEN
    RAISE EXCEPTION 'Insufficient token balance';
  END IF;

  UPDATE public.profiles SET token_balance = token_balance - _stake
  WHERE id = v_user RETURNING token_balance INTO v_new_balance;

  INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
  VALUES (v_user, -_stake, v_new_balance, 'lottery_stake', 'Lottery ticket: number ' || _number);

  UPDATE public.house_wallet
    SET balance = balance + _stake, total_in = total_in + _stake, updated_at = now()
    WHERE id = 1 RETURNING balance INTO v_house;

  INSERT INTO public.house_transactions (kind, amount, balance_after, user_id, reason)
  VALUES ('lottery_stake', _stake, COALESCE(v_house, 0), v_user, 'Lottery ticket');

  INSERT INTO public.lottery_tickets (draw_id, user_id, number, stake)
  VALUES (_draw_id, v_user, _number, _stake) RETURNING id INTO v_ticket_id;

  RETURN jsonb_build_object('ok', true, 'ticket_id', v_ticket_id, 'new_balance', v_new_balance);
END;
$$;

GRANT EXECUTE ON FUNCTION public.place_lottery_ticket(uuid, integer, bigint) TO authenticated;

-- Draw the lottery (admin): pick winner, settle tickets, pay winners from house
CREATE OR REPLACE FUNCTION public.draw_lottery(_draw_id uuid, _winning_number integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_draw public.lottery_draws%ROWTYPE;
  v_winner integer;
  v_ticket record;
  v_payout bigint;
  v_new_balance bigint;
  v_house bigint;
  v_winners integer := 0;
  v_total_payout bigint := 0;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  SELECT * INTO v_draw FROM public.lottery_draws WHERE id = _draw_id FOR UPDATE;
  IF v_draw.id IS NULL THEN
    RAISE EXCEPTION 'Draw not found';
  END IF;
  IF v_draw.status = 'drawn' THEN
    RAISE EXCEPTION 'This draw is already settled';
  END IF;

  v_winner := COALESCE(_winning_number, floor(random() * (v_draw.number_max + 1))::int);
  IF v_winner < 0 OR v_winner > v_draw.number_max THEN
    RAISE EXCEPTION 'Winning number out of range';
  END IF;

  FOR v_ticket IN
    SELECT * FROM public.lottery_tickets WHERE draw_id = _draw_id AND status = 'open'
  LOOP
    IF v_ticket.number = v_winner THEN
      v_payout := (v_ticket.stake * v_draw.multiplier)::bigint;
      UPDATE public.lottery_tickets SET status = 'won', payout = v_payout WHERE id = v_ticket.id;

      UPDATE public.profiles SET token_balance = token_balance + v_payout
      WHERE id = v_ticket.user_id RETURNING token_balance INTO v_new_balance;

      INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
      VALUES (v_ticket.user_id, v_payout, v_new_balance, 'lottery_win', 'Lottery win: number ' || v_winner);

      UPDATE public.house_wallet
        SET balance = balance - v_payout, total_out = total_out + v_payout, updated_at = now()
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
    SET status = 'drawn', winning_number = v_winner, drawn_at = now()
    WHERE id = _draw_id;

  RETURN jsonb_build_object('ok', true, 'winning_number', v_winner, 'winners', v_winners, 'total_payout', v_total_payout);
END;
$$;

GRANT EXECUTE ON FUNCTION public.draw_lottery(uuid, integer) TO authenticated;