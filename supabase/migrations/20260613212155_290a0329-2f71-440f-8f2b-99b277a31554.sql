DROP POLICY IF EXISTS "bracket_emblems_read" ON storage.objects;
DROP POLICY IF EXISTS "bracket_emblems_admin_write" ON storage.objects;
DROP POLICY IF EXISTS "event_banners_read" ON storage.objects;
DROP POLICY IF EXISTS "event_banners_admin_write" ON storage.objects;
DROP POLICY IF EXISTS "users upload own private files" ON storage.objects;
DROP POLICY IF EXISTS "users read own private files" ON storage.objects;
DROP POLICY IF EXISTS "users update own files" ON storage.objects;
DROP POLICY IF EXISTS "users delete own files" ON storage.objects;
DROP POLICY IF EXISTS "admins write public asset buckets" ON storage.objects;

CREATE POLICY "users upload own private files"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id IN ('ticket-uploads','token-proofs')
  AND auth.uid()::text = (storage.foldername(name))[1]
);

CREATE POLICY "users read own private files"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id IN ('ticket-uploads','token-proofs')
  AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid()))
);

CREATE POLICY "users update own private files"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id IN ('ticket-uploads','token-proofs')
  AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid()))
)
WITH CHECK (
  bucket_id IN ('ticket-uploads','token-proofs')
  AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid()))
);

CREATE POLICY "users delete own private files"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id IN ('ticket-uploads','token-proofs')
  AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid()))
);

CREATE POLICY "admins manage private uploads"
ON storage.objects
FOR ALL
TO authenticated
USING (bucket_id IN ('ticket-uploads','token-proofs') AND public.is_admin(auth.uid()))
WITH CHECK (bucket_id IN ('ticket-uploads','token-proofs') AND public.is_admin(auth.uid()));

CREATE POLICY "admins write public asset buckets"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id IN ('ads','announcements','highlights','team-logos','player-avatars','gang-emblems','event-banners','season-banners','popup-ads','chat-images')
  AND public.is_mod_or_admin(auth.uid())
);