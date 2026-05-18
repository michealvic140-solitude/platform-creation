# Virtual Gangs v2 — Auto-Play + Approved Payouts

A big upgrade to the Virtual Gangs system. Below is exactly what will change.

## 1. Auto-resolving cycle engine

A new admin-controlled engine that runs rounds in a loop:

- **Admin "Start cycle" button** — sets a global `virtual_cycle_running = true` flag in `app_settings`, then triggers the first round.
- **Admin "Pause cycle" button** — sets `virtual_cycle_running = false`. Any in-flight round finishes, but no new round auto-spawns. Admin can create/edit rounds while paused.
- **2-minute betting window** — when a round starts, `start_time = now()`, `lock_time = now() + 2 minutes`. Public page shows a big live countdown.
- **Auto-lock + auto-resolve** — when the timer reaches zero:
  - Markets close (status → `live`).
  - 15-second "match playing" animation runs client-side (kill ticker, score tracker).
  - Server RPC `auto_resolve_virtual_round` generates **random but varied** scores (0–8 each side, plus randomised first blood). Scores are guaranteed not identical to the previous round.
  - Match status → `ended`, winners computed, bets marked `won`/`lost` — but **payouts NOT credited yet** (held for admin review).
- **Auto-next round** — if cycle is running and no admin-scheduled rounds are pending, the engine picks 2 random teams from `teams` and spawns the next round with the same 4 markets.

Engine runs via `pg_cron` calling a `/api/public/hooks/virtual-tick` endpoint every 10 seconds.

## 2. "Watch the match" experience

On `/virtual`, when a round is `live` (post-lock, pre-settled):

- Card flips into a **play view**: animated dice/crosshair, kill-feed ticker ("⚔ Gang A scored!"), live score counter ticking up to the final result.
- Smooth 15-second build-up using `framer-motion`.
- When `status = ended`, a "Final" badge appears with W/D/L outcome strip.

The scores ticking up are purely visual — final numbers come from the server's resolve RPC.

## 3. Multi-selection betting + editable checkout

The current `/virtual` page uses a single-bet dialog. This will change to:

- Each market pick **adds to the existing `BetSlipContext`** (already used for normal matches).
- Floating bet slip shows all virtual selections, lets user adjust stake per leg or as accumulator, remove legs, then "Place ticket".
- Reuses the existing `BetSlip` component; virtual selections are tagged so checkout validates against `virtual_min_stake`/`virtual_max_stake`.
- Wallet balance enforced before submit.

## 4. Pending-approval payouts

New flow after a round resolves:

- Winning bets get `status = 'won'` but no tokens credited.
- A new row goes into `virtual_payout_requests` (status `pending`).
- User sees on `/virtual/history` and on the ticket: "🏆 Won — awaiting admin approval. Claim available once approved."
- **Admin panel** gets a new "Pending Payouts" tab:
  - List of all pending wins (user, round, stake, payout).
  - **Approve** → flips to `approved`, user can now click "Claim" to credit tokens.
  - **Decline** with reason → flips to `declined`, stake is refunded, user notified.
- User claim button calls `claim_virtual_payout(_request_id)` RPC — only works if `approved`.

## 5. Admin controls (Virtual tab)

```text
┌─ Cycle Engine ────────────────────────────┐
│  Status: ● RUNNING       [ Pause cycle ]  │
│  Next auto-spawn: in 0:42                 │
└───────────────────────────────────────────┘
┌─ Pending Payouts (12) ────────────────────┐
│  user · round · 250K → 750K  [✓] [✗]      │
│  ...                                       │
└───────────────────────────────────────────┘
┌─ Round Composer ──────────────────────────┐
│  (existing — manually queue specific rounds)│
└───────────────────────────────────────────┘
┌─ Reward Settings · Audit Log (existing)   │
└───────────────────────────────────────────┘
```

## 6. Score variation guarantee

`auto_resolve_virtual_round` rules:
- Random scores in `[0,8]` per side.
- Re-roll if `(home, away)` equals the most recent ended virtual match.
- Re-roll if both sides equal 0 more than once in a row.
- Outcome label derived: `home > away` → home win, `home < away` → away win, `home = away` → draw. The Match-Winner odds settle based on this. Correct-score/totals/first-blood already handled by existing resolve logic.

---

## Technical changes

**Migration** (`virtual_v2_engine.sql`)
- `app_settings`: add `virtual_cycle_running boolean`, `virtual_round_duration_seconds int default 120`, `virtual_resolve_animation_seconds int default 15`, `virtual_auto_payout boolean default false`.
- New table `virtual_payout_requests(id, bet_id, user_id, match_id, amount, status, reviewed_by, reviewed_at, decline_reason, created_at)` with RLS (user reads own, admin manages).
- New RPCs:
  - `admin_set_virtual_cycle(_running boolean)` — toggle engine.
  - `auto_resolve_virtual_round(_match_id uuid)` — random scores + variation guard, marks bets won/lost, inserts payout requests instead of crediting.
  - `virtual_tick()` — internal: lock rounds past `lock_time`, resolve rounds past `lock_time + animation_seconds`, spawn next round if cycle running and queue empty.
  - `admin_review_virtual_payout(_id uuid, _approve boolean, _reason text)` — credit or refund + notify.
  - `claim_virtual_payout(_id uuid)` — user claims approved payout, credits balance once.
  - `place_virtual_ticket(_selections jsonb, _stake bigint)` — multi-leg ticket replacement for the current single-pick RPC.

**Cron** — `pg_cron` job calling `/api/public/hooks/virtual-tick` every 10s with anon key.

**New/edited files**
- `src/routes/api/public/hooks/virtual-tick.ts` (new) — calls `virtual_tick()` via admin client.
- `src/routes/virtual.tsx` — countdown, watch-play animation, BetSlip integration.
- `src/routes/virtual.history.tsx` — show payout-approval state, "Claim" button.
- `src/components/admin/VirtualAdminPanel.tsx` — Cycle controls + Pending Payouts tab.
- `src/components/BetSlip.tsx` — small tweak to surface virtual stake limits.
- `src/contexts/BetSlipContext.tsx` — flag virtual selections.

**Out of scope**
- Provably-fair seeding (random is server-side only).
- Live odds movement during betting window.
- Animated 3D shooter visualisation (kept as ticker + score counter).

Confirm and I'll build it.
