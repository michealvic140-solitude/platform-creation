-- ============ SURVEYS ============
CREATE TABLE public.surveys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text,
  questions jsonb NOT NULL DEFAULT '[]'::jsonb,
  target_user_ids uuid[],
  is_active boolean NOT NULL DEFAULT true,
  expires_at timestamptz,
  created_by uuid REFERENCES auth.users,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.surveys TO authenticated;
GRANT ALL ON public.surveys TO service_role;
ALTER TABLE public.surveys ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view targeted active surveys" ON public.surveys FOR SELECT TO authenticated
  USING (public.is_admin(auth.uid()) OR (is_active AND (target_user_ids IS NULL OR auth.uid() = ANY(target_user_ids))));
CREATE POLICY "admins manage surveys" ON public.surveys FOR ALL TO authenticated
  USING (public.is_admin(auth.uid())) WITH CHECK (public.is_admin(auth.uid()));

CREATE TABLE public.survey_responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  survey_id uuid NOT NULL REFERENCES public.surveys(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  answers jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'submitted',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (survey_id, user_id)
);
GRANT SELECT, INSERT, UPDATE ON public.survey_responses TO authenticated;
GRANT ALL ON public.survey_responses TO service_role;
ALTER TABLE public.survey_responses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users manage own survey responses" ON public.survey_responses FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "admins view survey responses" ON public.survey_responses FOR SELECT TO authenticated
  USING (public.is_admin(auth.uid()));

CREATE TRIGGER update_surveys_updated_at BEFORE UPDATE ON public.surveys
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Submit / dismiss survey (idempotent)
CREATE OR REPLACE FUNCTION public.submit_survey(_survey_id uuid, _answers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  INSERT INTO public.survey_responses(survey_id, user_id, answers, status)
  VALUES (_survey_id, uid, COALESCE(_answers, '{}'::jsonb), 'submitted')
  ON CONFLICT (survey_id, user_id) DO UPDATE SET answers = EXCLUDED.answers, status = 'submitted';
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.dismiss_survey(_survey_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  INSERT INTO public.survey_responses(survey_id, user_id, answers, status)
  VALUES (_survey_id, uid, '{}'::jsonb, 'dismissed')
  ON CONFLICT (survey_id, user_id) DO NOTHING;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ============ TASKS: richer fields ============
ALTER TABLE public.user_tasks
  ADD COLUMN IF NOT EXISTS target_progress numeric NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS progress numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ends_at timestamptz,
  ADD COLUMN IF NOT EXISTS banner_url text,
  ADD COLUMN IF NOT EXISTS reward_kind text NOT NULL DEFAULT 'tokens',
  ADD COLUMN IF NOT EXISTS period text;

-- Auto-complete a task when progress reaches the target
CREATE OR REPLACE FUNCTION public.user_task_progress_check()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.status = 'pending' AND NEW.target_progress > 0 AND NEW.progress >= NEW.target_progress THEN
    NEW.status := 'completed';
    NEW.completed_at := COALESCE(NEW.completed_at, now());
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_user_task_progress ON public.user_tasks;
CREATE TRIGGER trg_user_task_progress BEFORE INSERT OR UPDATE ON public.user_tasks
  FOR EACH ROW EXECUTE FUNCTION public.user_task_progress_check();

-- ============ APP SETTINGS: task page background ============
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS tasks_bg_url text,
  ADD COLUMN IF NOT EXISTS tasks_bg_fit text DEFAULT 'cover',
  ADD COLUMN IF NOT EXISTS tasks_bg_position text DEFAULT 'center';