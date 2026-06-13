CREATE OR REPLACE FUNCTION public.audit_admin_change_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _actor uuid := auth.uid();
  _role text;
  _action text;
  _target_id text;
  _target_name text;
  _reason text;
  _meta jsonb := '{}'::jsonb;
  _match_status text;
BEGIN
  IF _actor IS NULL OR NOT public.is_staff(_actor) THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_TABLE_NAME = 'audit_logs' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_TABLE_NAME = 'matches' THEN
    _match_status := CASE WHEN TG_OP = 'DELETE' THEN OLD.status::text ELSE NEW.status::text END;
    IF COALESCE((CASE WHEN TG_OP = 'DELETE' THEN OLD.is_virtual ELSE NEW.is_virtual END), false)
       AND TG_OP <> 'INSERT'
       AND COALESCE(_match_status, '') IN ('scheduled','live','ended','cancelled')
       AND COALESCE((CASE WHEN TG_OP = 'DELETE' THEN OLD.locked_by ELSE NEW.locked_by END)::text, '') = ''
       AND COALESCE((CASE WHEN TG_OP = 'DELETE' THEN OLD.settled_by ELSE NEW.settled_by END)::text, '') = '' THEN
      RETURN COALESCE(NEW, OLD);
    END IF;
  END IF;

  _role := COALESCE(public.primary_role(_actor), 'staff');
  _target_id := COALESCE((to_jsonb(NEW)->>'id'), (to_jsonb(OLD)->>'id'));
  _target_name := COALESCE(
    to_jsonb(NEW)->>'full_name', to_jsonb(OLD)->>'full_name',
    to_jsonb(NEW)->>'email', to_jsonb(OLD)->>'email',
    to_jsonb(NEW)->>'name', to_jsonb(OLD)->>'name',
    to_jsonb(NEW)->>'title', to_jsonb(OLD)->>'title',
    to_jsonb(NEW)->>'tracking_id', to_jsonb(OLD)->>'tracking_id',
    to_jsonb(NEW)->>'code', to_jsonb(OLD)->>'code'
  );
  _reason := COALESCE(
    to_jsonb(NEW)->>'ban_reason', to_jsonb(NEW)->>'mute_reason', to_jsonb(NEW)->>'restrict_reason',
    to_jsonb(NEW)->>'admin_note', to_jsonb(NEW)->>'reason',
    to_jsonb(OLD)->>'ban_reason', to_jsonb(OLD)->>'mute_reason', to_jsonb(OLD)->>'restrict_reason',
    to_jsonb(OLD)->>'admin_note', to_jsonb(OLD)->>'reason'
  );

  _action := CASE TG_TABLE_NAME
    WHEN 'profiles' THEN CASE
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.is_banned,false) IS DISTINCT FROM COALESCE(NEW.is_banned,false) THEN CASE WHEN NEW.is_banned THEN 'banned_user' ELSE 'unbanned_user' END
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.is_muted,false) IS DISTINCT FROM COALESCE(NEW.is_muted,false) THEN CASE WHEN NEW.is_muted THEN 'suspension_mute_user' ELSE 'unsuspend_unmute_user' END
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.is_restricted,false) IS DISTINCT FROM COALESCE(NEW.is_restricted,false) THEN CASE WHEN NEW.is_restricted THEN 'restrict_user' ELSE 'remove_restrict_user' END
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.force_logout_at, 'epoch'::timestamptz) IS DISTINCT FROM COALESCE(NEW.force_logout_at, 'epoch'::timestamptz) THEN 'kick_user'
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.token_balance,0) IS DISTINCT FROM COALESCE(NEW.token_balance,0) THEN CASE WHEN COALESCE(NEW.token_balance,0) > COALESCE(OLD.token_balance,0) THEN 'grant_tokens' ELSE 'revoke_tokens' END
      ELSE lower(TG_OP) || '_profile'
    END
    WHEN 'user_roles' THEN CASE WHEN TG_OP = 'INSERT' THEN 'add_role' WHEN TG_OP = 'DELETE' THEN 'remove_role' ELSE 'update_role' END
    WHEN 'bets' THEN CASE
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.status::text,'') IS DISTINCT FROM COALESCE(NEW.status::text,'') THEN 'bet_' || COALESCE(NEW.status::text, 'updated')
      WHEN TG_OP = 'DELETE' THEN 'delete_bet'
      ELSE lower(TG_OP) || '_bet'
    END
    WHEN 'withdrawal_requests' THEN CASE
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.status::text,'') IS DISTINCT FROM COALESCE(NEW.status::text,'') THEN 'withdrawal_' || COALESCE(NEW.status::text, 'reviewed')
      ELSE lower(TG_OP) || '_withdrawal'
    END
    WHEN 'token_requests' THEN CASE
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.status::text,'') IS DISTINCT FROM COALESCE(NEW.status::text,'') THEN 'token_request_' || COALESCE(NEW.status::text, 'reviewed')
      ELSE lower(TG_OP) || '_token_request'
    END
    WHEN 'promo_code_requests' THEN CASE
      WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.status::text,'') IS DISTINCT FROM COALESCE(NEW.status::text,'') THEN 'promo_code_' || COALESCE(NEW.status::text, 'reviewed')
      ELSE lower(TG_OP) || '_promo_code_request'
    END
    WHEN 'promo_codes' THEN lower(TG_OP) || '_promo_code'
    WHEN 'matches' THEN CASE WHEN TG_OP = 'UPDATE' AND COALESCE(OLD.status::text,'') IS DISTINCT FROM COALESCE(NEW.status::text,'') THEN 'match_' || COALESCE(NEW.status::text, 'updated') ELSE lower(TG_OP) || '_match' END
    WHEN 'events' THEN lower(TG_OP) || '_event'
    WHEN 'announcements' THEN lower(TG_OP) || '_announcement'
    WHEN 'broadcasts' THEN lower(TG_OP) || '_broadcast'
    WHEN 'notifications' THEN lower(TG_OP) || '_notify'
    WHEN 'house_wallet' THEN 'house_wallet_' || lower(TG_OP)
    WHEN 'house_transactions' THEN 'house_' || lower(TG_OP)
    WHEN 'virtual_house_wallet' THEN 'virtual_house_wallet_' || lower(TG_OP)
    WHEN 'leaderboard_overrides' THEN lower(TG_OP) || '_leaderboard'
    WHEN 'challenges' THEN lower(TG_OP) || '_challenge'
    WHEN 'seasons' THEN lower(TG_OP) || '_season'
    WHEN 'user_tasks' THEN lower(TG_OP) || '_task'
    WHEN 'support_tickets' THEN lower(TG_OP) || '_support_ticket'
    WHEN 'chat_messages' THEN lower(TG_OP) || '_chat_message'
    WHEN 'ban_appeals' THEN lower(TG_OP) || '_ban_appeal'
    ELSE lower(TG_OP) || '_' || TG_TABLE_NAME
  END;

  _meta := jsonb_build_object(
    'actor_role', _role,
    'target_table', TG_TABLE_NAME,
    'operation', TG_OP,
    'target_name', _target_name,
    'reason', _reason,
    'audit_source', 'database_trigger',
    'timestamp_iso', now(),
    'where', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
    'dedupe_key', md5(_actor::text || '|' || TG_TABLE_NAME || '|' || TG_OP || '|' || COALESCE(_target_id,'') || '|' || date_trunc('second', now())::text)
  );

  IF TG_OP = 'UPDATE' THEN
    _meta := _meta || jsonb_build_object('before', to_jsonb(OLD), 'after', to_jsonb(NEW));
  ELSIF TG_OP = 'DELETE' THEN
    _meta := _meta || jsonb_build_object('before', to_jsonb(OLD));
  ELSE
    _meta := _meta || jsonb_build_object('after', to_jsonb(NEW));
  END IF;

  INSERT INTO public.audit_logs(actor_id, action, target_type, target_id, metadata)
  SELECT _actor, _action, TG_TABLE_NAME, _target_id, _meta
  WHERE NOT EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE actor_id = _actor
      AND action = _action
      AND COALESCE(target_type,'') = TG_TABLE_NAME
      AND COALESCE(target_id,'') = COALESCE(_target_id,'')
      AND created_at > now() - interval '2 seconds'
  );

  RETURN COALESCE(NEW, OLD);
END;
$function$;

DROP POLICY IF EXISTS "bracket emblems public read" ON storage.objects;
DROP POLICY IF EXISTS "admins manage bracket emblems" ON storage.objects;

CREATE POLICY "bracket emblems public read"
ON storage.objects
FOR SELECT
TO public
USING (bucket_id = 'bracket-emblems');

CREATE POLICY "admins manage bracket emblems"
ON storage.objects
FOR ALL
TO authenticated
USING (bucket_id = 'bracket-emblems' AND public.is_admin(auth.uid()))
WITH CHECK (bucket_id = 'bracket-emblems' AND public.is_admin(auth.uid()));