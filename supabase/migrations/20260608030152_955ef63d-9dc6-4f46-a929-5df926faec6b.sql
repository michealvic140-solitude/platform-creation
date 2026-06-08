CREATE OR REPLACE FUNCTION public.is_staff(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role IN ('admin', 'moderator')
  )
$$;

CREATE OR REPLACE FUNCTION public.primary_role(_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role::text
  FROM public.user_roles
  WHERE user_id = _user_id
  ORDER BY CASE role
    WHEN 'admin' THEN 1
    WHEN 'moderator' THEN 2
    WHEN 'sponsor' THEN 3
    ELSE 9
  END
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.admin_log_action(
  _action text,
  _target_type text DEFAULT NULL,
  _target_id text DEFAULT NULL,
  _metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _actor uuid := auth.uid();
  _role text;
  _dedupe text;
  _existing uuid;
  _id uuid;
BEGIN
  IF _actor IS NULL OR NOT public.is_staff(_actor) THEN
    RAISE EXCEPTION 'Admin or moderator role required';
  END IF;

  _role := COALESCE(public.primary_role(_actor), 'staff');
  _dedupe := COALESCE(_metadata->>'dedupe_key', md5(_actor::text || '|' || COALESCE(_action,'') || '|' || COALESCE(_target_type,'') || '|' || COALESCE(_target_id,'') || '|' || date_trunc('second', now())::text));

  SELECT id INTO _existing
  FROM public.audit_logs
  WHERE actor_id = _actor
    AND action = _action
    AND COALESCE(target_type, '') = COALESCE(_target_type, '')
    AND COALESCE(target_id, '') = COALESCE(_target_id, '')
    AND metadata->>'dedupe_key' = _dedupe
  LIMIT 1;

  IF _existing IS NOT NULL THEN
    RETURN _existing;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, target_type, target_id, metadata)
  VALUES (
    _actor,
    _action,
    _target_type,
    _target_id,
    COALESCE(_metadata, '{}'::jsonb) || jsonb_build_object(
      'actor_role', _role,
      'dedupe_key', _dedupe,
      'timestamp_iso', now(),
      'audit_source', COALESCE(_metadata->>'audit_source', 'admin_panel')
    )
  )
  RETURNING id INTO _id;

  RETURN _id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_staff(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.primary_role(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_log_action(text, text, text, jsonb) TO authenticated, service_role;
GRANT SELECT, INSERT ON public.audit_logs TO authenticated;
GRANT ALL ON public.audit_logs TO service_role;

DROP POLICY IF EXISTS "admins read logs" ON public.audit_logs;
CREATE POLICY "staff read audit logs"
ON public.audit_logs
FOR SELECT
TO authenticated
USING (public.is_staff(auth.uid()));

DROP POLICY IF EXISTS "staff insert audit logs through helper" ON public.audit_logs;
CREATE POLICY "staff insert audit logs through helper"
ON public.audit_logs
FOR INSERT
TO authenticated
WITH CHECK (public.is_staff(auth.uid()) AND actor_id = auth.uid());

CREATE OR REPLACE FUNCTION public.audit_admin_change_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _actor uuid := auth.uid();
  _role text;
  _action text;
  _target_id text;
  _target_name text;
  _reason text;
  _meta jsonb := '{}'::jsonb;
BEGIN
  IF _actor IS NULL OR NOT public.is_staff(_actor) THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_TABLE_NAME = 'audit_logs' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_TABLE_NAME = 'matches'
     AND COALESCE((CASE WHEN TG_OP = 'DELETE' THEN OLD.is_virtual ELSE NEW.is_virtual END), false)
     AND (TG_OP <> 'INSERT')
     AND COALESCE((CASE WHEN TG_OP = 'DELETE' THEN OLD.status ELSE NEW.status END), '') IN ('open','live','ended')
     AND COALESCE((CASE WHEN TG_OP = 'DELETE' THEN OLD.locked_by ELSE NEW.locked_by END)::text, '') = ''
     AND COALESCE((CASE WHEN TG_OP = 'DELETE' THEN OLD.settled_by ELSE NEW.settled_by END)::text, '') = '' THEN
    RETURN COALESCE(NEW, OLD);
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
$$;

DROP TRIGGER IF EXISTS audit_admin_profiles ON public.profiles;
CREATE TRIGGER audit_admin_profiles AFTER UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_user_roles ON public.user_roles;
CREATE TRIGGER audit_admin_user_roles AFTER INSERT OR UPDATE OR DELETE ON public.user_roles FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_bets ON public.bets;
CREATE TRIGGER audit_admin_bets AFTER INSERT OR UPDATE OR DELETE ON public.bets FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_withdrawals ON public.withdrawal_requests;
CREATE TRIGGER audit_admin_withdrawals AFTER UPDATE OR DELETE ON public.withdrawal_requests FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_token_requests ON public.token_requests;
CREATE TRIGGER audit_admin_token_requests AFTER UPDATE OR DELETE ON public.token_requests FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_promo_requests ON public.promo_code_requests;
CREATE TRIGGER audit_admin_promo_requests AFTER UPDATE OR DELETE ON public.promo_code_requests FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_promo_codes ON public.promo_codes;
CREATE TRIGGER audit_admin_promo_codes AFTER INSERT OR UPDATE OR DELETE ON public.promo_codes FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_matches ON public.matches;
CREATE TRIGGER audit_admin_matches AFTER INSERT OR UPDATE OR DELETE ON public.matches FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_events ON public.events;
CREATE TRIGGER audit_admin_events AFTER INSERT OR UPDATE OR DELETE ON public.events FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_announcements ON public.announcements;
CREATE TRIGGER audit_admin_announcements AFTER INSERT OR UPDATE OR DELETE ON public.announcements FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_broadcasts ON public.broadcasts;
CREATE TRIGGER audit_admin_broadcasts AFTER INSERT OR UPDATE OR DELETE ON public.broadcasts FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_notifications ON public.notifications;
CREATE TRIGGER audit_admin_notifications AFTER INSERT OR UPDATE OR DELETE ON public.notifications FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_house_wallet ON public.house_wallet;
CREATE TRIGGER audit_admin_house_wallet AFTER UPDATE ON public.house_wallet FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_house_transactions ON public.house_transactions;
CREATE TRIGGER audit_admin_house_transactions AFTER INSERT OR UPDATE OR DELETE ON public.house_transactions FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_virtual_house_wallet ON public.virtual_house_wallet;
CREATE TRIGGER audit_admin_virtual_house_wallet AFTER UPDATE ON public.virtual_house_wallet FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_leaderboard ON public.leaderboard_overrides;
CREATE TRIGGER audit_admin_leaderboard AFTER INSERT OR UPDATE OR DELETE ON public.leaderboard_overrides FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_challenges ON public.challenges;
CREATE TRIGGER audit_admin_challenges AFTER INSERT OR UPDATE OR DELETE ON public.challenges FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_seasons ON public.seasons;
CREATE TRIGGER audit_admin_seasons AFTER INSERT OR UPDATE OR DELETE ON public.seasons FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_user_tasks ON public.user_tasks;
CREATE TRIGGER audit_admin_user_tasks AFTER INSERT OR UPDATE OR DELETE ON public.user_tasks FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_support_tickets ON public.support_tickets;
CREATE TRIGGER audit_admin_support_tickets AFTER UPDATE OR DELETE ON public.support_tickets FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_chat_messages ON public.chat_messages;
CREATE TRIGGER audit_admin_chat_messages AFTER DELETE ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();
DROP TRIGGER IF EXISTS audit_admin_ban_appeals ON public.ban_appeals;
CREATE TRIGGER audit_admin_ban_appeals AFTER UPDATE OR DELETE ON public.ban_appeals FOR EACH ROW EXECUTE FUNCTION public.audit_admin_change_trigger();