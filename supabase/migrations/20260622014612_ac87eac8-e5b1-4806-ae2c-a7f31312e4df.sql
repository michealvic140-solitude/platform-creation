-- Hero background admin controls
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS hero_bg_url text,
  ADD COLUMN IF NOT EXISTS hero_bg_fit text NOT NULL DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS hero_bg_position text NOT NULL DEFAULT 'center';

-- Unique public Special ID for every user
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS special_id text;

CREATE OR REPLACE FUNCTION public.gen_special_id()
RETURNS text
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
  i int;
  exists_already boolean;
BEGIN
  LOOP
    candidate := '';
    FOR i IN 1..7 LOOP
      candidate := candidate || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    END LOOP;
    SELECT EXISTS(SELECT 1 FROM public.profiles WHERE special_id = candidate) INTO exists_already;
    IF NOT exists_already THEN
      RETURN candidate;
    END IF;
  END LOOP;
END;
$$;

-- Backfill existing users
UPDATE public.profiles
SET special_id = public.gen_special_id()
WHERE special_id IS NULL;

-- Enforce uniqueness + auto-assign for new rows
CREATE UNIQUE INDEX IF NOT EXISTS profiles_special_id_key ON public.profiles (special_id);

CREATE OR REPLACE FUNCTION public.assign_special_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.special_id IS NULL THEN
    NEW.special_id := public.gen_special_id();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assign_special_id ON public.profiles;
CREATE TRIGGER trg_assign_special_id
  BEFORE INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.assign_special_id();

-- Safe recipient lookup by Special ID (returns display info only)
CREATE OR REPLACE FUNCTION public.resolve_special_id(_special_id text)
RETURNS TABLE (id uuid, full_name text, special_id text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.full_name, p.special_id
  FROM public.profiles p
  WHERE upper(p.special_id) = upper(trim(_special_id))
  LIMIT 1;
$$;

-- Secure token transfer between users by Special ID
CREATE OR REPLACE FUNCTION public.transfer_tokens(_recipient_special_id text, _amount bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender uuid := auth.uid();
  v_recipient uuid;
  v_recipient_name text;
  v_sender_balance bigint;
  v_new_sender bigint;
  v_new_recipient bigint;
BEGIN
  IF v_sender IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF _amount IS NULL OR _amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero';
  END IF;

  SELECT id, full_name INTO v_recipient, v_recipient_name
  FROM public.profiles
  WHERE upper(special_id) = upper(trim(_recipient_special_id))
  LIMIT 1;

  IF v_recipient IS NULL THEN
    RAISE EXCEPTION 'No user found with that Special ID';
  END IF;
  IF v_recipient = v_sender THEN
    RAISE EXCEPTION 'You cannot transfer tokens to yourself';
  END IF;

  -- Lock sender row and check balance
  SELECT token_balance INTO v_sender_balance
  FROM public.profiles WHERE id = v_sender FOR UPDATE;

  IF v_sender_balance < _amount THEN
    RAISE EXCEPTION 'Insufficient token balance';
  END IF;

  UPDATE public.profiles SET token_balance = token_balance - _amount
  WHERE id = v_sender RETURNING token_balance INTO v_new_sender;

  UPDATE public.profiles SET token_balance = token_balance + _amount
  WHERE id = v_recipient RETURNING token_balance INTO v_new_recipient;

  INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
  VALUES (v_sender, -_amount, v_new_sender, 'transfer_out', 'Transfer to ' || v_recipient_name);

  INSERT INTO public.token_transactions (user_id, amount, balance_after, kind, description)
  VALUES (v_recipient, _amount, v_new_recipient, 'transfer_in', 'Transfer received');

  RETURN jsonb_build_object('ok', true, 'recipient_name', v_recipient_name, 'new_balance', v_new_sender);
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_special_id(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_tokens(text, bigint) TO authenticated;