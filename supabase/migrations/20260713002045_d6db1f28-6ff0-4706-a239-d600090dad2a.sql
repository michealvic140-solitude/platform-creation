-- 1) FIX: the profile-protection trigger was reverting token_balance for every
--    non-admin user, so regular members were never debited when placing bets,
--    never debited on withdrawal requests, and never credited when claiming
--    virtual payouts. Trusted SECURITY DEFINER functions run as the function
--    owner (current_user = 'postgres'); only direct client updates arrive as
--    the 'authenticated'/'anon' roles, so restrict those and let trusted
--    server-side functions through.
CREATE OR REPLACE FUNCTION public.protect_profile_sensitive_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Trusted backend (service role), admins, and privileged SECURITY DEFINER
  -- functions (which execute as their owner, not the client role) may set
  -- sensitive fields directly.
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
END;
$function$;

-- 2) Admin fan-out helper: insert one notification per admin. Each inserted
--    notification triggers the existing queue_push_for_notification bridge,
--    which delivers a web-push to every saved device of that admin — so admins
--    are alerted even when they are not on the site.
CREATE OR REPLACE FUNCTION public.notify_admins(_title text, _body text, _link text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.notifications(user_id, title, body, link)
  SELECT DISTINCT ur.user_id, _title, _body, COALESCE(_link, '/admin')
  FROM public.user_roles ur
  WHERE ur.role = 'admin';
END;
$function$;

-- Small helper to resolve a friendly display name for a user id.
CREATE OR REPLACE FUNCTION public.display_name_for(_uid uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(NULLIF(TRIM(full_name), ''), 'A user') FROM public.profiles WHERE id = _uid
$function$;

-- 3) Event triggers → admin device notifications --------------------------------

-- Bet placed
CREATE OR REPLACE FUNCTION public.notify_admins_bet_placed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.notify_admins(
    'New bet placed',
    public.display_name_for(NEW.user_id) || ' staked ' || NEW.stake::text ||
      ' tokens · ' || COALESCE(NEW.tracking_id, 'ticket'),
    '/ticket/' || NEW.id::text
  );
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_notify_admins_bet ON public.bets;
CREATE TRIGGER trg_notify_admins_bet
  AFTER INSERT ON public.bets
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_bet_placed();

-- Token request
CREATE OR REPLACE FUNCTION public.notify_admins_token_request()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.notify_admins(
    'New token request',
    public.display_name_for(NEW.user_id) || ' requested ' || NEW.amount::text || ' tokens.',
    '/admin'
  );
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_notify_admins_token_request ON public.token_requests;
CREATE TRIGGER trg_notify_admins_token_request
  AFTER INSERT ON public.token_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_token_request();

-- Support ticket created
CREATE OR REPLACE FUNCTION public.notify_admins_support_ticket()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.notify_admins(
    'New support ticket',
    public.display_name_for(NEW.user_id) || ': ' || COALESCE(NEW.subject, 'New ticket'),
    '/admin'
  );
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_notify_admins_support_ticket ON public.support_tickets;
CREATE TRIGGER trg_notify_admins_support_ticket
  AFTER INSERT ON public.support_tickets
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_support_ticket();

-- Withdrawal request
CREATE OR REPLACE FUNCTION public.notify_admins_withdrawal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.notify_admins(
    'New withdrawal request',
    public.display_name_for(NEW.user_id) || ' requested ' || NEW.amount::text || ' tokens.',
    '/admin'
  );
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_notify_admins_withdrawal ON public.withdrawal_requests;
CREATE TRIGGER trg_notify_admins_withdrawal
  AFTER INSERT ON public.withdrawal_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_withdrawal();

-- Promo code request
CREATE OR REPLACE FUNCTION public.notify_admins_promo_request()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.notify_admins(
    'New promo code request',
    public.display_name_for(NEW.user_id) || ' requested a promo code (' || COALESCE(NEW.amount, 0)::text || ' tokens).',
    '/admin'
  );
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_notify_admins_promo_request ON public.promo_code_requests;
CREATE TRIGGER trg_notify_admins_promo_request
  AFTER INSERT ON public.promo_code_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_promo_request();

-- Virtual payout request created → alert admins so they can approve it
CREATE OR REPLACE FUNCTION public.notify_admins_virtual_payout()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.notify_admins(
    'Virtual payout to approve',
    public.display_name_for(NEW.user_id) || ' won ' || NEW.amount::text || ' tokens on a virtual ticket.',
    '/admin'
  );
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_notify_admins_virtual_payout ON public.virtual_payout_requests;
CREATE TRIGGER trg_notify_admins_virtual_payout
  AFTER INSERT ON public.virtual_payout_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_virtual_payout();