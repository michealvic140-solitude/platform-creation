-- Staging tables for legacy data import (no auth.users FK so we can hold orphan rows)

CREATE TABLE IF NOT EXISTS public.imported_user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legacy_id uuid,
  old_user_id uuid NOT NULL,
  email text,
  role public.app_role NOT NULL,
  legacy_created_at timestamptz,
  claimed_at timestamptz,
  claimed_user_id uuid
);
CREATE INDEX IF NOT EXISTS idx_imp_roles_user ON public.imported_user_roles(old_user_id);
ALTER TABLE public.imported_user_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins manage imp roles" ON public.imported_user_roles
  FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.imported_token_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legacy_id uuid,
  old_user_id uuid NOT NULL,
  amount bigint NOT NULL,
  balance_after bigint NOT NULL,
  kind text NOT NULL,
  description text,
  metadata jsonb,
  legacy_created_at timestamptz,
  claimed_at timestamptz,
  claimed_user_id uuid
);
CREATE INDEX IF NOT EXISTS idx_imp_tx_user ON public.imported_token_transactions(old_user_id);
ALTER TABLE public.imported_token_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins manage imp tx" ON public.imported_token_transactions
  FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.imported_withdrawal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legacy_id uuid,
  old_user_id uuid NOT NULL,
  ingame_name text,
  gang_name text,
  amount bigint NOT NULL,
  ticket_ref text,
  status text,
  admin_note text,
  reviewed_at timestamptz,
  legacy_created_at timestamptz,
  claimed_at timestamptz,
  claimed_user_id uuid
);
CREATE INDEX IF NOT EXISTS idx_imp_wd_user ON public.imported_withdrawal_requests(old_user_id);
ALTER TABLE public.imported_withdrawal_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins manage imp wd" ON public.imported_withdrawal_requests
  FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.imported_token_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legacy_id uuid,
  old_user_id uuid NOT NULL,
  amount bigint NOT NULL,
  proof_image_url text,
  note text,
  status text,
  review_note text,
  reviewed_at timestamptz,
  legacy_created_at timestamptz,
  claimed_at timestamptz,
  claimed_user_id uuid
);
CREATE INDEX IF NOT EXISTS idx_imp_tr_user ON public.imported_token_requests(old_user_id);
ALTER TABLE public.imported_token_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins manage imp tr" ON public.imported_token_requests
  FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

-- Archive-only (no replay due to match/market/odd FKs being skipped)
CREATE TABLE IF NOT EXISTS public.imported_bets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legacy_id uuid,
  old_user_id uuid NOT NULL,
  tracking_id text,
  booking_code text,
  stake bigint,
  total_odds numeric,
  potential_payout bigint,
  status text,
  cashout_amount bigint,
  legacy_created_at timestamptz,
  settled_at timestamptz,
  cashed_out_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_imp_bets_user ON public.imported_bets(old_user_id);
ALTER TABLE public.imported_bets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins read imp bets" ON public.imported_bets
  FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE IF NOT EXISTS public.imported_bet_selections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legacy_id uuid,
  legacy_bet_id uuid,
  legacy_match_id uuid,
  legacy_market_id uuid,
  legacy_odd_id uuid,
  locked_odds numeric,
  selection_label text,
  result text,
  legacy_created_at timestamptz
);
ALTER TABLE public.imported_bet_selections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins read imp sel" ON public.imported_bet_selections
  FOR ALL TO authenticated USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

-- Map old_user_id -> email (so we can resolve to new auth user). Derived from profiles via apply_imported_profile.claimed_user_id.
-- Replay function: called on user creation, restores roles + tx + wd + tr by old_user_id matched via imported_profiles email lookup.

CREATE OR REPLACE FUNCTION public.apply_imported_user_data(_new_user_id uuid, _email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  imp record;
  old_uid uuid;
  roles_added int := 0;
  tx_added int := 0;
  wd_added int := 0;
  tr_added int := 0;
BEGIN
  -- Find the matching imported_profiles row to learn the OLD user_id (we stored it nowhere yet — derive from token_transactions by matching email won't work). 
  -- Instead: we add an old_user_id column to imported_profiles if missing.
  SELECT * INTO imp FROM public.imported_profiles WHERE lower(email) = lower(_email) LIMIT 1;
  IF imp IS NULL THEN RETURN jsonb_build_object('skipped', true); END IF;

  old_uid := imp.old_user_id;
  IF old_uid IS NULL THEN RETURN jsonb_build_object('no_old_uid', true); END IF;

  -- Replay roles (skip 'viewer' since handle_new_user already inserts it)
  INSERT INTO public.user_roles(user_id, role)
  SELECT _new_user_id, ir.role
  FROM public.imported_user_roles ir
  WHERE ir.old_user_id = old_uid
    AND ir.claimed_at IS NULL
    AND ir.role <> 'viewer'
  ON CONFLICT (user_id, role) DO NOTHING;
  GET DIAGNOSTICS roles_added = ROW_COUNT;
  UPDATE public.imported_user_roles SET claimed_at = now(), claimed_user_id = _new_user_id
    WHERE old_user_id = old_uid AND claimed_at IS NULL;

  -- Replay token transactions
  INSERT INTO public.token_transactions(user_id, amount, balance_after, kind, description, metadata, created_at)
  SELECT _new_user_id, it.amount, it.balance_after, it.kind, it.description, it.metadata, COALESCE(it.legacy_created_at, now())
  FROM public.imported_token_transactions it
  WHERE it.old_user_id = old_uid AND it.claimed_at IS NULL;
  GET DIAGNOSTICS tx_added = ROW_COUNT;
  UPDATE public.imported_token_transactions SET claimed_at = now(), claimed_user_id = _new_user_id
    WHERE old_user_id = old_uid AND claimed_at IS NULL;

  -- Replay withdrawal requests
  INSERT INTO public.withdrawal_requests(user_id, ingame_name, gang_name, amount, ticket_ref, status, admin_note, reviewed_at, created_at)
  SELECT _new_user_id,
    COALESCE(iw.ingame_name, 'imported'),
    COALESCE(iw.gang_name, 'imported'),
    iw.amount,
    iw.ticket_ref,
    COALESCE(iw.status, 'pending')::withdrawal_status,
    iw.admin_note,
    iw.reviewed_at,
    COALESCE(iw.legacy_created_at, now())
  FROM public.imported_withdrawal_requests iw
  WHERE iw.old_user_id = old_uid AND iw.claimed_at IS NULL;
  GET DIAGNOSTICS wd_added = ROW_COUNT;
  UPDATE public.imported_withdrawal_requests SET claimed_at = now(), claimed_user_id = _new_user_id
    WHERE old_user_id = old_uid AND claimed_at IS NULL;

  -- Replay token requests
  INSERT INTO public.token_requests(user_id, amount, proof_image_url, note, status, review_note, reviewed_at, created_at)
  SELECT _new_user_id, ir2.amount, ir2.proof_image_url, ir2.note,
    COALESCE(ir2.status, 'pending')::token_request_status,
    ir2.review_note, ir2.reviewed_at, COALESCE(ir2.legacy_created_at, now())
  FROM public.imported_token_requests ir2
  WHERE ir2.old_user_id = old_uid AND ir2.claimed_at IS NULL;
  GET DIAGNOSTICS tr_added = ROW_COUNT;
  UPDATE public.imported_token_requests SET claimed_at = now(), claimed_user_id = _new_user_id
    WHERE old_user_id = old_uid AND claimed_at IS NULL;

  RETURN jsonb_build_object('roles', roles_added, 'tx', tx_added, 'wd', wd_added, 'tr', tr_added);
END $$;

-- Need old_user_id on imported_profiles so we can map. Add column if missing.
ALTER TABLE public.imported_profiles ADD COLUMN IF NOT EXISTS old_user_id uuid;
CREATE INDEX IF NOT EXISTS idx_imp_profiles_old_uid ON public.imported_profiles(old_user_id);

-- Hook replay into existing handle_new_user
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email, phone, discord_username, discord_full_name, ingame_name, country, server, gang_name, gang_type)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email,'@',1)),
    NEW.email,
    NEW.raw_user_meta_data->>'phone',
    NEW.raw_user_meta_data->>'discord_username',
    NEW.raw_user_meta_data->>'discord_full_name',
    NEW.raw_user_meta_data->>'ingame_name',
    NEW.raw_user_meta_data->>'country',
    COALESCE(NEW.raw_user_meta_data->>'server','LOMITA AFR'),
    NEW.raw_user_meta_data->>'gang_name',
    NULLIF(NEW.raw_user_meta_data->>'gang_type','')::public.gang_type
  );
  IF NEW.email = 'lomitashootersleague@gmail.com' THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'admin');
  ELSE
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'viewer');
  END IF;

  PERFORM public.apply_imported_profile(NEW.id, NEW.email);
  PERFORM public.apply_imported_user_data(NEW.id, NEW.email);

  RETURN NEW;
END $$;
