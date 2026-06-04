CREATE OR REPLACE FUNCTION public.redeem_referral_code(_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid uuid := auth.uid();
  ref_profile public.profiles%ROWTYPE;
  cfg record;
  normalized text := upper(trim(_code));
BEGIN
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'unauth'); END IF;
  IF normalized = '' OR normalized IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_code');
  END IF;
  IF EXISTS (SELECT 1 FROM public.referral_redemptions WHERE user_id = uid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_redeemed');
  END IF;
  SELECT * INTO ref_profile FROM public.profiles
   WHERE upper(referral_code) = normalized LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'code_not_found'); END IF;
  IF ref_profile.id = uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_referral');
  END IF;
  SELECT COALESCE(referral_bonus_referee, 0) AS referee_bonus,
         COALESCE(referral_bonus_referrer, 0) AS referrer_bonus
    INTO cfg FROM public.app_settings WHERE id = 1;
  INSERT INTO public.referral_redemptions (user_id, referrer_id, code, referee_bonus, referrer_bonus)
    VALUES (uid, ref_profile.id, normalized, cfg.referee_bonus, cfg.referrer_bonus);
  INSERT INTO public.referrals (referrer_id, referee_id, referrer_bonus, referee_bonus)
    VALUES (ref_profile.id, uid, cfg.referrer_bonus, cfg.referee_bonus);
  UPDATE public.profiles SET token_balance = token_balance + cfg.referee_bonus,
                              referred_by = ref_profile.id WHERE id = uid;
  UPDATE public.profiles SET token_balance = token_balance + cfg.referrer_bonus WHERE id = ref_profile.id;
  IF cfg.referee_bonus > 0 THEN
    INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
      SELECT uid, cfg.referee_bonus, token_balance, 'referral_redeem', 'Redeemed referral ' || normalized
        FROM public.profiles WHERE id = uid;
  END IF;
  IF cfg.referrer_bonus > 0 THEN
    INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
      SELECT ref_profile.id, cfg.referrer_bonus, token_balance, 'referral_bonus', 'Referral bonus from ' || uid::text
        FROM public.profiles WHERE id = ref_profile.id;
    INSERT INTO public.notifications (user_id, title, body, link)
      VALUES (ref_profile.id, 'Referral bonus', cfg.referrer_bonus || ' tokens credited for a referred sign-up.', '/dashboard');
  END IF;
  RETURN jsonb_build_object('ok', true, 'referee_bonus', cfg.referee_bonus, 'referrer_bonus', cfg.referrer_bonus);
END $$;

CREATE OR REPLACE FUNCTION public.admin_clear_leaderboard()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RETURN jsonb_build_object('ok', false); END IF;
  TRUNCATE TABLE public.season_points;
  DELETE FROM public.leaderboard_overrides;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_leaderboard_override(
  _id uuid, _kind text, _name text, _top_player text,
  _wins integer, _losses integer, _draws integer, _played integer,
  _points bigint, _manual_rank integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE new_id uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RETURN jsonb_build_object('ok', false); END IF;
  IF _id IS NULL THEN
    INSERT INTO public.leaderboard_overrides
      (kind, name, top_player, wins, losses, draws, played, points, manual_rank)
      VALUES (_kind, _name, _top_player, _wins, _losses, _draws, _played, _points, _manual_rank)
      RETURNING id INTO new_id;
  ELSE
    UPDATE public.leaderboard_overrides SET
      kind = _kind, name = _name, top_player = _top_player,
      wins = _wins, losses = _losses, draws = _draws, played = _played,
      points = _points, manual_rank = _manual_rank
      WHERE id = _id RETURNING id INTO new_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', new_id);
END $$;

CREATE OR REPLACE FUNCTION public.admin_delete_leaderboard_override(_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RETURN jsonb_build_object('ok', false); END IF;
  DELETE FROM public.leaderboard_overrides WHERE id = _id;
  RETURN jsonb_build_object('ok', true);
END $$;