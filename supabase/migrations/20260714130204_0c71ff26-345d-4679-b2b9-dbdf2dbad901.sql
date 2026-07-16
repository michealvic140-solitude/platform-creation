ALTER TABLE public.matches DROP CONSTRAINT matches_home_team_id_fkey;
ALTER TABLE public.matches ADD CONSTRAINT matches_home_team_id_fkey FOREIGN KEY (home_team_id) REFERENCES public.teams(id) ON DELETE CASCADE;
ALTER TABLE public.matches DROP CONSTRAINT matches_away_team_id_fkey;
ALTER TABLE public.matches ADD CONSTRAINT matches_away_team_id_fkey FOREIGN KEY (away_team_id) REFERENCES public.teams(id) ON DELETE CASCADE;
ALTER TABLE public.matches DROP CONSTRAINT matches_winner_team_id_fkey;
ALTER TABLE public.matches ADD CONSTRAINT matches_winner_team_id_fkey FOREIGN KEY (winner_team_id) REFERENCES public.teams(id) ON DELETE SET NULL;