ALTER TABLE public.push_subscriptions
  ADD COLUMN IF NOT EXISTS locale text;

CREATE INDEX IF NOT EXISTS idx_push_subscriptions_enabled_user ON public.push_subscriptions(enabled, user_id);
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_locale ON public.push_subscriptions(locale) WHERE enabled = true;
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_last_seen ON public.push_subscriptions(last_seen_at DESC) WHERE enabled = true;
CREATE INDEX IF NOT EXISTS idx_user_sessions_last_seen_user ON public.user_sessions(last_seen DESC, user_id);

CREATE OR REPLACE FUNCTION public.touch_push_subscription()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.last_seen_at = COALESCE(NEW.last_seen_at, now());
  IF NEW.enabled IS TRUE THEN
    NEW.disabled_at = NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_push_subscription ON public.push_subscriptions;
CREATE TRIGGER trg_touch_push_subscription
BEFORE INSERT OR UPDATE ON public.push_subscriptions
FOR EACH ROW EXECUTE FUNCTION public.touch_push_subscription();