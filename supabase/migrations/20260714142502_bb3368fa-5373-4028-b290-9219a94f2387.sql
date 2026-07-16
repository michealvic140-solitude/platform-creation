-- Championship engine stores team ids directly in tournament_matches.participant_*
-- Drop the FKs that pointed at tournament_participants so championship_start can insert team ids.
ALTER TABLE public.tournament_matches DROP CONSTRAINT IF EXISTS tournament_matches_participant_a_id_fkey;
ALTER TABLE public.tournament_matches DROP CONSTRAINT IF EXISTS tournament_matches_participant_b_id_fkey;
ALTER TABLE public.tournament_matches DROP CONSTRAINT IF EXISTS tournament_matches_winner_id_fkey;