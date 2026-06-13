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
  _new_j jsonb;
  _old_j jsonb;
BEGIN
  IF _actor IS NULL OR NOT public.is_staff(_actor) THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_TABLE_NAME = 'audit_logs' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  _new_j := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) ELSE NULL END;
  _old_j := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) ELSE NULL END;

  IF TG_TABLE_NAME = 'matches' THEN
    _match_status := COALESCE(_new_j->>'status', _old_j->>'status');
    IF COALESCE((COALESCE(_new_j, _old_j)->>'is_virtual')::boolean, false)
       AND TG_OP <> 'INSERT'
       AND COALESCE(_match_status, '') IN ('scheduled','live','ended','cancelled')
       AND COALESCE(COALESCE(_new_j, _old_j)->>'locked_by', '') = ''
       AND COALESCE(COALESCE(_new_j, _old_j)->>'settled_by', '') = '' THEN
      RETURN COALESCE(NEW, OLD);
    END IF;
  END IF;

  _role := COALESCE(public.primary_role(_actor), 'staff');
  _target_id := COALESCE(_new_j->>'id', _old_j->>'id');
  _target_name := COALESCE(
    _new_j->>'full_name', _old_j->>'full_name',
    _new_j->>'email', _old_j->>'email',
    _new_j->>'name', _old_j->>'name',
    _new_j->>'title', _old_j->>'title',
    _new_j->>'tracking_id', _old_j->>'tracking_id',
    _new_j->>'code', _old_j->>'code'
  );
  _reason := COALESCE(
    _new_j->>'ban_reason', _new_j->>'mute_reason', _new_j->>'restrict_reason',
    _new_j->>'admin_note', _new_j->>'reason',
    _old_j->>'ban_reason', _old_j->>'mute_reason', _old_j->>'restrict_reason',
    _old_j->>'admin_note', _old_j->>'reason'
  );

  IF TG_TABLE_NAME = 'profiles' THEN
    IF TG_OP = 'UPDATE' AND COALESCE((_old_j->>'is_banned')::boolean,false) IS DISTINCT FROM COALESCE((_new_j->>'is_banned')::boolean,false) THEN
      _action := CASE WHEN (_new_j->>'is_banned')::boolean THEN 'banned_user' ELSE 'unbanned_user' END;
    ELSIF TG_OP = 'UPDATE' AND COALESCE((_old_j->>'is_muted')::boolean,false) IS DISTINCT FROM COALESCE((_new_j->>'is_muted')::boolean,false) THEN
      _action := CASE WHEN (_new_j->>'is_muted')::boolean THEN 'suspension_mute_user' ELSE 'unsuspend_unmute_user' END;
    ELSIF TG_OP = 'UPDATE' AND COALESCE((_old_j->>'is_restricted')::boolean,false) IS DISTINCT FROM COALESCE((_new_j->>'is_restricted')::boolean,false) THEN
      _action := CASE WHEN (_new_j->>'is_restricted')::boolean THEN 'restrict_user' ELSE 'remove_restrict_user' END;
    ELSIF TG_OP = 'UPDATE' AND COALESCE(_old_j->>'force_logout_at', '') IS DISTINCT FROM COALESCE(_new_j->>'force_logout_at', '') THEN
      _action := 'kick_user';
    ELSIF TG_OP = 'UPDATE' AND COALESCE((_old_j->>'token_balance')::bigint,0) IS DISTINCT FROM COALESCE((_new_j->>'token_balance')::bigint,0) THEN
      _action := CASE WHEN COALESCE((_new_j->>'token_balance')::bigint,0) > COALESCE((_old_j->>'token_balance')::bigint,0) THEN 'grant_tokens' ELSE 'revoke_tokens' END;
    ELSE
      _action := lower(TG_OP) || '_profile';
    END IF;
  ELSIF TG_TABLE_NAME = 'user_roles' THEN
    _action := CASE WHEN TG_OP = 'INSERT' THEN 'add_role' WHEN TG_OP = 'DELETE' THEN 'remove_role' ELSE 'update_role' END;
  ELSIF TG_TABLE_NAME = 'bets' THEN
    IF TG_OP = 'UPDATE' AND COALESCE(_old_j->>'status','') IS DISTINCT FROM COALESCE(_new_j->>'status','') THEN
      _action := 'bet_' || COALESCE(_new_j->>'status','updated');
    ELSIF TG_OP = 'DELETE' THEN
      _action := 'delete_bet';
    ELSE
      _action := lower(TG_OP) || '_bet';
    END IF;
  ELSIF TG_TABLE_NAME = 'withdrawal_requests' THEN
    IF TG_OP = 'UPDATE' AND COALESCE(_old_j->>'status','') IS DISTINCT FROM COALESCE(_new_j->>'status','') THEN
      _action := 'withdrawal_' || COALESCE(_new_j->>'status','reviewed');
    ELSE
      _action := lower(TG_OP) || '_withdrawal';
    END IF;
  ELSIF TG_TABLE_NAME = 'token_requests' THEN
    IF TG_OP = 'UPDATE' AND COALESCE(_old_j->>'status','') IS DISTINCT FROM COALESCE(_new_j->>'status','') THEN
      _action := 'token_request_' || COALESCE(_new_j->>'status','reviewed');
    ELSE
      _action := lower(TG_OP) || '_token_request';
    END IF;
  ELSIF TG_TABLE_NAME = 'promo_code_requests' THEN
    IF TG_OP = 'UPDATE' AND COALESCE(_old_j->>'status','') IS DISTINCT FROM COALESCE(_new_j->>'status','') THEN
      _action := 'promo_code_' || COALESCE(_new_j->>'status','reviewed');
    ELSE
      _action := lower(TG_OP) || '_promo_code_request';
    END IF;
  ELSIF TG_TABLE_NAME = 'promo_codes' THEN
    _action := lower(TG_OP) || '_promo_code';
  ELSIF TG_TABLE_NAME = 'matches' THEN
    IF TG_OP = 'UPDATE' AND COALESCE(_old_j->>'status','') IS DISTINCT FROM COALESCE(_new_j->>'status','') THEN
      _action := 'match_' || COALESCE(_new_j->>'status','updated');
    ELSE
      _action := lower(TG_OP) || '_match';
    END IF;
  ELSIF TG_TABLE_NAME = 'events' THEN _action := lower(TG_OP) || '_event';
  ELSIF TG_TABLE_NAME = 'announcements' THEN _action := lower(TG_OP) || '_announcement';
  ELSIF TG_TABLE_NAME = 'broadcasts' THEN _action := lower(TG_OP) || '_broadcast';
  ELSIF TG_TABLE_NAME = 'notifications' THEN _action := lower(TG_OP) || '_notify';
  ELSIF TG_TABLE_NAME = 'house_wallet' THEN _action := 'house_wallet_' || lower(TG_OP);
  ELSIF TG_TABLE_NAME = 'house_transactions' THEN _action := 'house_' || lower(TG_OP);
  ELSIF TG_TABLE_NAME = 'virtual_house_wallet' THEN _action := 'virtual_house_wallet_' || lower(TG_OP);
  ELSIF TG_TABLE_NAME = 'leaderboard_overrides' THEN _action := lower(TG_OP) || '_leaderboard';
  ELSIF TG_TABLE_NAME = 'challenges' THEN _action := lower(TG_OP) || '_challenge';
  ELSIF TG_TABLE_NAME = 'seasons' THEN _action := lower(TG_OP) || '_season';
  ELSIF TG_TABLE_NAME = 'user_tasks' THEN _action := lower(TG_OP) || '_task';
  ELSIF TG_TABLE_NAME = 'support_tickets' THEN _action := lower(TG_OP) || '_support_ticket';
  ELSIF TG_TABLE_NAME = 'chat_messages' THEN _action := lower(TG_OP) || '_chat_message';
  ELSIF TG_TABLE_NAME = 'ban_appeals' THEN _action := lower(TG_OP) || '_ban_appeal';
  ELSE
    _action := lower(TG_OP) || '_' || TG_TABLE_NAME;
  END IF;

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
    _meta := _meta || jsonb_build_object('before', _old_j, 'after', _new_j);
  ELSIF TG_OP = 'DELETE' THEN
    _meta := _meta || jsonb_build_object('before', _old_j);
  ELSE
    _meta := _meta || jsonb_build_object('after', _new_j);
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