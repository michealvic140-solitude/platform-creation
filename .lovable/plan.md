
# Instant Virtual Gangs — Plan

A new "Virtual" section where users bet on quick (~30s) gang-vs-gang instant rounds. Gangs are pulled from registered gangs (the distinct `gang_name` values across `profiles`). Admin creates, runs, and resolves each round from the admin panel; outcomes are not auto-generated.

## User experience

- New nav entry **Virtual** (next to Matches).
- `/virtual` page shows:
  - The **current live round** (countdown to lock, two gang emblems, 4 markets with odds).
  - A short **upcoming rounds** strip (next 3 scheduled).
  - **Recent results** strip with winning selections highlighted.
- Tapping any odd adds it to the existing BetSlip — same flow as real matches, so payouts, tracking IDs, and ticket pages all work unchanged.
- When the round locks (countdown hits 0), selections become unclickable and the card flips to a "Drawing result…" state until the admin publishes the result; ticket then settles automatically (same path as real matches).

## Markets per round

1. **Match winner** — Gang A / Draw / Gang B
2. **First blood** — Gang A / Gang B (which gang scores first)
3. **Total kills O/U** — Over X.5 / Under X.5 (admin sets line)
4. **Correct score** — common scorelines (admin-configured list, high odds)

Admin can toggle which markets appear per round and edit odds before lock.

## Admin panel additions (new "Virtual" tab)

- **Round composer**: pick Gang A / Gang B from registered-gang dropdown, set start time, lock time (default start+25s), enable markets, edit odds & O/U line, edit correct-score grid.
- **Quick-create**: "Create next round" button that auto-pairs two random registered gangs with default odds.
- **Live control**: list of rounds with status pills (`scheduled` → `live` → `locked` → `resolved`); buttons to **Lock now**, **Publish result**, **Void & refund**.
- **Resolve form**: enter final score `A:B` and first-blood gang. Backend computes winners for all 4 markets, marks each `odds.is_winner`, and reuses the existing settlement pipeline so bets pay out exactly like real matches (no parallel payout code).

## Data model (uses existing tables, no parallel system)

The cleanest approach is to model each round as a `matches` row with a new category and dedicated teams, so the entire BetSlip / `bets` / `bet_selections` / payout machinery works untouched.

- Insert a category `Virtual Gangs` in `categories`.
- For each registered gang name, lazy-create a row in `teams` (name = gang name) the first time it's used in a virtual round.
- A virtual round = `matches` row with `category = Virtual Gangs`, `start_time` = round start, plus `markets` + `odds` rows for the enabled markets.
- New columns on `matches` (migration): `is_virtual boolean default false`, `lock_time timestamptz null`, `auto_settle boolean default false`. Existing pages filter `is_virtual = false` so virtual rounds don't pollute the regular Matches page.
- New RPC `resolve_virtual_round(_match_id, _home_score, _away_score, _first_blood_team_id)` (security definer, admin-only) that:
  1. Sets `odds.is_winner` for every market based on the inputs.
  2. Calls the existing settlement path used after a real match ends.
  3. Marks the match `status = 'ended'`.

## Routes & files

- `src/routes/virtual.tsx` — public page.
- `src/components/virtual/VirtualRoundCard.tsx` — live round + countdown + market tabs.
- `src/components/virtual/VirtualResultsStrip.tsx`.
- `src/components/admin/VirtualAdminPanel.tsx` — composer + live control + resolve form, mounted in `src/routes/admin.tsx` as a new tab.
- `src/lib/virtual.ts` — fetch helpers (current/upcoming/recent rounds).
- Migration: add columns, category seed, new RPC.
- Layout nav: add **Virtual** link (desktop nav + mobile bottom bar).

## Out of scope (can come later)

- Auto-scheduled rounds / cron.
- Animated reveal (we'll start with a simple flip + result text; can layer Motion later).
- Provably-fair seeding (engine is admin-controlled per your choice).

Confirm and I'll start with the migration, then build the page, then the admin panel.
