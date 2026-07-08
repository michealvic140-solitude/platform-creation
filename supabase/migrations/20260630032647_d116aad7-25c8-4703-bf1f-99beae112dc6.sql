CREATE TABLE IF NOT EXISTS public.push_delivery_log (
  notification_id uuid PRIMARY KEY REFERENCES public.notifications(id) ON DELETE CASCADE,
  sent_count integer NOT NULL DEFAULT 0,
  removed_count integer NOT NULL DEFAULT 0,
  last_error text,
  delivered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.push_delivery_log TO authenticated;
GRANT ALL ON public.push_delivery_log TO service_role;
ALTER TABLE public.push_delivery_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "push delivery admins read" ON public.push_delivery_log;
CREATE POLICY "push delivery admins read" ON public.push_delivery_log FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS push_delivery_log_updated_at ON public.push_delivery_log;
CREATE TRIGGER push_delivery_log_updated_at BEFORE UPDATE ON public.push_delivery_log FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.push_subscriptions ADD COLUMN IF NOT EXISTS last_seen_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.push_subscriptions ADD COLUMN IF NOT EXISTS disabled_at timestamptz;
ALTER TABLE public.push_subscriptions ADD COLUMN IF NOT EXISTS failure_count integer NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX IF NOT EXISTS push_subscriptions_endpoint_uidx ON public.push_subscriptions(endpoint);

CREATE OR REPLACE FUNCTION public.queue_push_for_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text;
BEGIN
  IF NEW.user_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.push_delivery_log(notification_id)
  VALUES (NEW.id)
  ON CONFLICT (notification_id) DO NOTHING;

  SELECT push_endpoint_url INTO v_url FROM public.app_settings_private WHERE id = 1;
  IF v_url IS NOT NULL AND length(trim(v_url)) > 0 THEN
    PERFORM net.http_post(
      url := v_url,
      body := jsonb_build_object('notification_id', NEW.id),
      headers := jsonb_build_object('Content-Type','application/json'),
      timeout_milliseconds := 5000
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS queue_push_for_notification_trigger ON public.notifications;
CREATE TRIGGER queue_push_for_notification_trigger
AFTER INSERT ON public.notifications
FOR EACH ROW EXECUTE FUNCTION public.queue_push_for_notification();

DROP POLICY IF EXISTS "poll votes own insert" ON public.poll_votes;
DROP POLICY IF EXISTS "poll votes own update" ON public.poll_votes;
CREATE POLICY "poll votes own insert" ON public.poll_votes FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "poll votes own update" ON public.poll_votes FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
GRANT UPDATE ON public.poll_votes TO authenticated;