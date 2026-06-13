-- Broadcasts: internal metadata, only used in admin screens. Remove broad read.
DROP POLICY IF EXISTS "broadcasts read authed" ON public.broadcasts;

-- Friends: scope reads to the user's own relationships instead of everyone.
DROP POLICY IF EXISTS "friends read authed" ON public.friends;
CREATE POLICY "friends own read" ON public.friends
  FOR SELECT TO authenticated
  USING (follower_id = auth.uid() OR followee_id = auth.uid());