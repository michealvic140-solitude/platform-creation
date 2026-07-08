-- 1. Missing admin bet actions: void + refund
CREATE OR REPLACE FUNCTION public.admin_void_bet(_bet_id uuid, _refund boolean DEFAULT false, _reason text DEFAULT NULL::text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE b record;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO b FROM public.bets WHERE id=_bet_id FOR UPDATE;
  IF b IS NULL THEN RAISE EXCEPTION 'Bet not found'; END IF;
  IF b.status IN ('void','refunded') THEN RAISE EXCEPTION 'Ticket already % — cannot void again', b.status; END IF;
  IF _refund AND b.status IN ('won','cashed_out') THEN
    RAISE EXCEPTION 'Stake already settled — cannot refund again (status: %)', b.status;
  END IF;
  IF _refund THEN
    UPDATE public.profiles SET token_balance = token_balance + b.stake WHERE id = b.user_id;
  END IF;
  UPDATE public.bets SET status='void', settled_at = COALESCE(settled_at, now()) WHERE id=_bet_id;
  INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (b.user_id, 'Ticket voided', COALESCE(_reason,'Your bet ticket has been voided by an admin.') || CASE WHEN _refund THEN ' Stake refunded.' ELSE '' END, '/ticket/'||_bet_id);
  INSERT INTO public.audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (auth.uid(), 'void_bet', 'bet', _bet_id::text, jsonb_build_object('reason', _reason, 'refunded', _refund, 'stake', b.stake));
END $function$;

CREATE OR REPLACE FUNCTION public.admin_refund_bet(_bet_id uuid, _reason text DEFAULT NULL::text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE b record;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT * INTO b FROM public.bets WHERE id=_bet_id FOR UPDATE;
  IF b IS NULL THEN RAISE EXCEPTION 'Bet not found'; END IF;
  IF b.status IN ('refunded','won','cashed_out') THEN
    RAISE EXCEPTION 'Stake already settled or refunded — cannot refund again (status: %)', b.status;
  END IF;
  UPDATE public.profiles SET token_balance = token_balance + b.stake WHERE id = b.user_id;
  UPDATE public.bets SET status='refunded', settled_at = COALESCE(settled_at, now()) WHERE id=_bet_id;
  INSERT INTO public.notifications(user_id, title, body, link)
    VALUES (b.user_id, 'Ticket refunded', COALESCE(_reason,'Your bet stake has been refunded by an admin.') || ' +' || b.stake || ' tokens.', '/ticket/'||_bet_id);
  INSERT INTO public.audit_logs(actor_id, action, target_type, target_id, metadata)
    VALUES (auth.uid(), 'refund_bet', 'bet', _bet_id::text, jsonb_build_object('reason', _reason, 'stake', b.stake));
END $function$;

-- 2. Leaderboard Total Score column
ALTER TABLE public.leaderboard_overrides ADD COLUMN IF NOT EXISTS total_score integer NOT NULL DEFAULT 0;

-- 3. Match attendance (present / absent per side). Default present so existing matches are unaffected.
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS home_present boolean NOT NULL DEFAULT true;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS away_present boolean NOT NULL DEFAULT true;

-- 4. Future tournament: restrict repeating the same contender across a user's tickets
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS restrict_repeat_contender boolean NOT NULL DEFAULT false;