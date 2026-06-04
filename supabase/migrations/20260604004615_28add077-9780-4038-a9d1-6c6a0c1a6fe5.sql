-- Chat message interaction fields
ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS reply_to_id uuid REFERENCES public.chat_messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS edited_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by uuid;

CREATE TABLE IF NOT EXISTS public.chat_message_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  emoji text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (message_id, user_id, emoji)
);

GRANT SELECT, INSERT, DELETE ON public.chat_message_reactions TO authenticated;
GRANT ALL ON public.chat_message_reactions TO service_role;

ALTER TABLE public.chat_message_reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "reactions readable by authed" ON public.chat_message_reactions;
CREATE POLICY "reactions readable by authed"
ON public.chat_message_reactions
FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS "users react as self" ON public.chat_message_reactions;
CREATE POLICY "users react as self"
ON public.chat_message_reactions
FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id AND length(emoji) BETWEEN 1 AND 16);

DROP POLICY IF EXISTS "users remove own reaction" ON public.chat_message_reactions;
CREATE POLICY "users remove own reaction"
ON public.chat_message_reactions
FOR DELETE TO authenticated
USING (auth.uid() = user_id OR public.is_mod_or_admin(auth.uid()));

DROP POLICY IF EXISTS "users edit own chat" ON public.chat_messages;
CREATE POLICY "users edit own chat"
ON public.chat_messages
FOR UPDATE TO authenticated
USING (auth.uid() = user_id OR public.is_mod_or_admin(auth.uid()))
WITH CHECK (auth.uid() = user_id OR public.is_mod_or_admin(auth.uid()));

DROP POLICY IF EXISTS "users delete own chat" ON public.chat_messages;
CREATE POLICY "users delete own chat"
ON public.chat_messages
FOR DELETE TO authenticated
USING (auth.uid() = user_id OR public.is_mod_or_admin(auth.uid()));

CREATE INDEX IF NOT EXISTS idx_chat_messages_reply_to ON public.chat_messages(reply_to_id);
CREATE INDEX IF NOT EXISTS idx_chat_reactions_message ON public.chat_message_reactions(message_id);

-- Leaderboard override hidden flag
ALTER TABLE public.leaderboard_overrides ADD COLUMN IF NOT EXISTS is_hidden boolean NOT NULL DEFAULT false;

-- Extend user_sessions with richer activity tracking
ALTER TABLE public.user_sessions
  ADD COLUMN IF NOT EXISTS session_start timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS signed_in_at timestamptz,
  ADD COLUMN IF NOT EXISTS ip_address text,
  ADD COLUMN IF NOT EXISTS device_type text,
  ADD COLUMN IF NOT EXISTS browser text,
  ADD COLUMN IF NOT EXISTS os text;

-- Referral redemptions table
CREATE TABLE IF NOT EXISTS public.referral_redemptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE,
  referrer_id uuid NOT NULL,
  code text NOT NULL,
  referee_bonus bigint NOT NULL DEFAULT 0,
  referrer_bonus bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON public.referral_redemptions TO authenticated;
GRANT ALL ON public.referral_redemptions TO service_role;

ALTER TABLE public.referral_redemptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "own referral redemption read" ON public.referral_redemptions;
CREATE POLICY "own referral redemption read"
  ON public.referral_redemptions FOR SELECT TO authenticated
  USING (auth.uid() = user_id OR auth.uid() = referrer_id OR public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "referral redemption admin" ON public.referral_redemptions;
CREATE POLICY "referral redemption admin"
  ON public.referral_redemptions FOR ALL TO authenticated
  USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE INDEX IF NOT EXISTS idx_referral_redemptions_referrer
  ON public.referral_redemptions(referrer_id);