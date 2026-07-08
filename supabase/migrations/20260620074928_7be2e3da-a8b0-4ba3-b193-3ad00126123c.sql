
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS nav_bg_url text,
  ADD COLUMN IF NOT EXISTS nav_bg_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS nav_bg_position text DEFAULT 'center';

CREATE OR REPLACE FUNCTION public.recalc_vip_tier(_user_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE cur_xp bigint; new_tier text; old_tier text;
  tier_rank int; old_rank int;
BEGIN
  SELECT xp, vip_tier INTO cur_xp, old_tier FROM public.profiles WHERE id = _user_id;
  IF cur_xp IS NULL THEN RETURN NULL; END IF;
  new_tier := CASE
    WHEN cur_xp >= 250000 THEN 'immortal'
    WHEN cur_xp >= 100000 THEN 'titan'
    WHEN cur_xp >= 50000  THEN 'mythic'
    WHEN cur_xp >= 25000  THEN 'legend'
    WHEN cur_xp >= 10000  THEN 'platinum'
    WHEN cur_xp >= 3000   THEN 'gold'
    WHEN cur_xp >= 500    THEN 'silver'
    ELSE 'bronze'
  END;
  IF new_tier <> COALESCE(old_tier,'bronze') THEN
    UPDATE public.profiles SET vip_tier = new_tier WHERE id = _user_id;
    tier_rank := CASE new_tier WHEN 'bronze' THEN 1 WHEN 'silver' THEN 2 WHEN 'gold' THEN 3 WHEN 'platinum' THEN 4 WHEN 'legend' THEN 5 WHEN 'mythic' THEN 6 WHEN 'titan' THEN 7 ELSE 8 END;
    old_rank  := CASE COALESCE(old_tier,'bronze') WHEN 'bronze' THEN 1 WHEN 'silver' THEN 2 WHEN 'gold' THEN 3 WHEN 'platinum' THEN 4 WHEN 'legend' THEN 5 WHEN 'mythic' THEN 6 WHEN 'titan' THEN 7 ELSE 8 END;
    IF tier_rank > old_rank THEN
      INSERT INTO public.notifications(user_id, title, body, link)
        VALUES (_user_id, '🎉 VIP Tier Up!', 'You have reached ' || upper(new_tier) || ' tier.', '/dashboard');
    END IF;
  END IF;
  RETURN new_tier;
END $function$;

CREATE OR REPLACE FUNCTION public.admin_adjust_xp(_user_id uuid, _delta integer, _reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE new_xp bigint; new_tier text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  UPDATE profiles SET xp = GREATEST(0, xp + _delta) WHERE id = _user_id RETURNING xp INTO new_xp;
  new_tier := CASE
    WHEN new_xp >= 250000 THEN 'immortal'
    WHEN new_xp >= 100000 THEN 'titan'
    WHEN new_xp >= 50000  THEN 'mythic'
    WHEN new_xp >= 25000  THEN 'legend'
    WHEN new_xp >= 10000  THEN 'platinum'
    WHEN new_xp >= 3000   THEN 'gold'
    WHEN new_xp >= 500    THEN 'silver'
    ELSE 'bronze' END;
  UPDATE profiles SET vip_tier = new_tier WHERE id = _user_id;
  INSERT INTO audit_logs(actor_id, action, target_type, target_id, metadata) VALUES (auth.uid(), 'admin_adjust_xp', 'profile', _user_id::text, jsonb_build_object('delta', _delta, 'reason', _reason, 'new_xp', new_xp));
  RETURN jsonb_build_object('xp', new_xp, 'vip_tier', new_tier);
END $function$;

CREATE OR REPLACE FUNCTION public.verify_xp_consistency(_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE checked int := 0; fixed int := 0; r record; calc_xp bigint; rules record; new_tier text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'Admin only'; END IF;
  SELECT xp_per_bet, xp_per_win, xp_per_login, xp_per_referral INTO rules FROM app_settings WHERE id = 1;
  FOR r IN SELECT id, xp, vip_tier FROM profiles WHERE (_user_id IS NULL OR id = _user_id) LOOP
    checked := checked + 1;
    SELECT
      COALESCE((SELECT count(*) FROM bets WHERE user_id = r.id),0) * rules.xp_per_bet +
      COALESCE((SELECT count(*) FROM bets WHERE user_id = r.id AND status='won'),0) * rules.xp_per_win +
      COALESCE((SELECT count(*) FROM referrals WHERE referrer_id = r.id),0) * rules.xp_per_referral
      INTO calc_xp;
    new_tier := CASE
      WHEN calc_xp >= 250000 THEN 'immortal'
      WHEN calc_xp >= 100000 THEN 'titan'
      WHEN calc_xp >= 50000  THEN 'mythic'
      WHEN calc_xp >= 25000  THEN 'legend'
      WHEN calc_xp >= 10000  THEN 'platinum'
      WHEN calc_xp >= 3000   THEN 'gold'
      WHEN calc_xp >= 500    THEN 'silver'
      ELSE 'bronze' END;
    IF r.xp <> calc_xp OR r.vip_tier <> new_tier THEN
      UPDATE profiles SET xp = calc_xp, vip_tier = new_tier WHERE id = r.id;
      fixed := fixed + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('checked', checked, 'fixed', fixed);
END $function$;
