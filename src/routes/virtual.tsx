import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Layout } from "@/components/Layout";
import { PageShell } from "@/components/PageShell";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from "@/components/ui/dialog";
import { Dice5, Lock, Flame, Trophy, Clock, History, Coins, CheckCircle2 } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/contexts/AuthContext";
import { Countdown } from "@/components/Countdown";
import { TeamLogo } from "@/components/TeamLogo";
import type { MatchRow } from "@/lib/queries";
import { toast } from "sonner";
import { useNavigate } from "@tanstack/react-router";

export const Route = createFileRoute("/virtual")({
  head: () => ({
    meta: [
      { title: "Virtual Gangs — Instant Rounds | LSL" },
      { name: "description", content: "Quick gang vs gang instant rounds. Pick winners, scores, and first blood every 30 seconds." },
    ],
  }),
  component: VirtualPage,
});

const matchSelect = `
  id,name,status,start_time,location,is_featured,home_score,away_score,is_virtual,lock_time,
  home_team:teams!home_team_id(id,name,logo_url,gang_type),
  away_team:teams!away_team_id(id,name,logo_url,gang_type),
  markets(id,name,is_open,odds(id,label,value,is_winner,market_id))
`;

function VirtualPage() {
  const [live, setLive] = useState<MatchRow[]>([]);
  const [upcoming, setUpcoming] = useState<MatchRow[]>([]);
  const [recent, setRecent] = useState<MatchRow[]>([]);

  useEffect(() => {
    const load = async () => {
      const nowIso = new Date().toISOString();
      const [{ data: liveRows }, { data: upRows }, { data: recRows }] = await Promise.all([
        supabase.from("matches").select(matchSelect).eq("is_virtual", true).in("status", ["scheduled", "live"]).lte("start_time", nowIso).order("start_time", { ascending: false }).limit(3),
        supabase.from("matches").select(matchSelect).eq("is_virtual", true).eq("status", "scheduled").gt("start_time", nowIso).order("start_time", { ascending: true }).limit(6),
        supabase.from("matches").select(matchSelect).eq("is_virtual", true).eq("status", "ended").order("start_time", { ascending: false }).limit(8),
      ]);
      setLive((liveRows ?? []) as unknown as MatchRow[]);
      setUpcoming((upRows ?? []) as unknown as MatchRow[]);
      setRecent((recRows ?? []) as unknown as MatchRow[]);
    };
    load();
    const t = setInterval(load, 5000);
    const ch = supabase.channel("virtual-rounds")
      .on("postgres_changes", { event: "*", schema: "public", table: "matches", filter: "is_virtual=eq.true" }, load)
      .subscribe();
    return () => { clearInterval(t); supabase.removeChannel(ch); };
  }, []);

  return (
    <Layout>
      <PageShell tone="default">
        <div className="container py-6 sm:py-10 space-y-8">
          <header className="text-center relative">
            <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-primary/15 border border-primary/40 text-[10px] uppercase tracking-[0.3em] text-primary mb-3">
              <Dice5 className="h-3.5 w-3.5" /> Instant Virtuals
            </div>
            <h1 className="text-3xl sm:text-5xl font-black gradient-gold-text">Gang vs Gang · Live Now</h1>
            <p className="text-muted-foreground mt-2 text-sm">Tap a market to place an instant bet. Tokens are deducted immediately.</p>
            <div className="mt-4 flex justify-center">
              <Link to="/virtual/history"><Button variant="outline" size="sm"><History className="h-3.5 w-3.5 mr-1" />Rounds history</Button></Link>
            </div>
          </header>

          {live.length === 0 && upcoming.length === 0 ? (
            <Card className="glass p-8 text-center text-muted-foreground">
              <Dice5 className="h-10 w-10 mx-auto mb-3 opacity-50" />
              <p className="font-semibold">No virtual rounds active right now.</p>
              <p className="text-xs mt-1">Check back in a minute — new rounds drop fast.</p>
            </Card>
          ) : (
            <>
              {live.length > 0 && (
                <section>
                  <SectionTitle icon={Flame} label="Live now" color="text-destructive" />
                  <div className="grid gap-4 md:grid-cols-2">
                    {live.map((m) => <VirtualRoundCard key={m.id} match={m} />)}
                  </div>
                </section>
              )}

              {upcoming.length > 0 && (
                <section>
                  <SectionTitle icon={Clock} label="Up next" color="text-primary" />
                  <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
                    {upcoming.map((m) => <VirtualRoundCard key={m.id} match={m} compact />)}
                  </div>
                </section>
              )}
            </>
          )}

          {recent.length > 0 && (
            <section>
              <SectionTitle icon={Trophy} label="Recent results" color="text-emerald-400" />
              <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                {recent.map((m) => (
                  <Card key={m.id} className="glass p-3">
                    <div className="text-[10px] uppercase tracking-widest text-muted-foreground truncate">{m.name}</div>
                    <div className="flex items-center justify-between mt-2 gap-2">
                      <div className="flex items-center gap-1.5 min-w-0">
                        <TeamLogo name={m.home_team?.name ?? ""} url={m.home_team?.logo_url ?? null} size={22} rounded="full" />
                        <span className="text-xs font-bold truncate">{m.home_team?.name}</span>
                      </div>
                      <span className="font-mono font-black text-base text-primary tabular-nums">{m.home_score} - {m.away_score}</span>
                      <div className="flex items-center gap-1.5 min-w-0 flex-row-reverse">
                        <TeamLogo name={m.away_team?.name ?? ""} url={m.away_team?.logo_url ?? null} size={22} rounded="full" />
                        <span className="text-xs font-bold truncate">{m.away_team?.name}</span>
                      </div>
                    </div>
                  </Card>
                ))}
              </div>
            </section>
          )}
        </div>
      </PageShell>
    </Layout>
  );
}

function SectionTitle({ icon: Icon, label, color }: { icon: any; label: string; color: string }) {
  return (
    <div className="flex items-center gap-2 mb-3">
      <Icon className={`h-4 w-4 ${color}`} />
      <h2 className="text-sm font-black uppercase tracking-[0.25em]">{label}</h2>
      <div className="flex-1 h-px bg-gradient-to-r from-border to-transparent" />
    </div>
  );
}

function VirtualRoundCard({ match, compact }: { match: MatchRow & { lock_time?: string | null }; compact?: boolean }) {
  const home = match.home_team?.name ?? "Home";
  const away = match.away_team?.name ?? "Away";
  const lockTime = (match as any).lock_time as string | null;
  const [, setTick] = useState(0);
  useEffect(() => { const t = setInterval(() => setTick((n) => n + 1), 1000); return () => clearInterval(t); }, []);
  const isLockedByTime = lockTime ? new Date(lockTime).getTime() <= Date.now() : false;
  const settled = match.status === "ended";
  const locked = settled || match.status !== "scheduled" || isLockedByTime;

  const [pickFor, setPickFor] = useState<{ marketId: string; marketName: string; oddId: string; label: string; value: number } | null>(null);

  const statusTone = settled ? "bg-emerald-500/15 border-emerald-500/40 text-emerald-400"
    : locked ? "bg-destructive/15 border-destructive/40 text-destructive"
    : "bg-primary/15 border-primary/40 text-primary";
  const statusLabel = settled ? "● SETTLED" : locked ? "● LOCKED" : "● OPEN";

  const order = (n: string) => /match\s*winner/i.test(n) ? 0 : /first\s*blood/i.test(n) ? 1 : /total|over\/under/i.test(n) ? 2 : /correct\s*score/i.test(n) ? 3 : 4;
  const markets = [...(match.markets ?? [])].sort((a, b) => order(a.name) - order(b.name));

  return (
    <Card className="glass p-4 relative overflow-hidden border-primary/30">
      <div className={`absolute top-0 right-0 px-2 py-0.5 text-[10px] font-bold tracking-widest rounded-bl-md border ${statusTone}`}>
        {statusLabel}
      </div>
      <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Instant Virtual</div>

      <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-3 mt-2">
        <div className="flex items-center gap-2 min-w-0">
          <TeamLogo name={home} url={match.home_team?.logo_url ?? null} size={42} rounded="full" />
          <div className="min-w-0">
            <div className="font-black truncate text-sm">{home}</div>
            <div className="text-[10px] text-muted-foreground">Gang A</div>
          </div>
        </div>
        <div className="text-center">
          <div className="text-[9px] text-muted-foreground uppercase tracking-widest">VS</div>
          {settled ? (
            <div className="font-mono font-black text-base text-emerald-400 tabular-nums">{match.home_score}-{match.away_score}</div>
          ) : (
            <Dice5 className="h-6 w-6 text-primary mx-auto animate-pulse" />
          )}
        </div>
        <div className="flex items-center gap-2 flex-row-reverse text-right min-w-0">
          <TeamLogo name={away} url={match.away_team?.logo_url ?? null} size={42} rounded="full" />
          <div className="min-w-0">
            <div className="font-black truncate text-sm">{away}</div>
            <div className="text-[10px] text-muted-foreground">Gang B</div>
          </div>
        </div>
      </div>

      <div className="mt-3 text-center text-xs">
        {settled ? (
          <span className="text-emerald-400 font-bold flex items-center justify-center gap-1"><CheckCircle2 className="h-3 w-3" />Result published</span>
        ) : locked ? (
          <span className="text-destructive font-bold flex items-center justify-center gap-1"><Lock className="h-3 w-3" />Drawing result…</span>
        ) : lockTime ? (
          <span className="text-muted-foreground">Locks in <span className="font-bold text-primary"><Countdown target={lockTime} /></span></span>
        ) : (
          <span className="text-muted-foreground">Starts <Countdown target={match.start_time} /></span>
        )}
      </div>

      {!compact && (
        <div className="mt-3 space-y-2">
          {markets.map((mk) => {
            const isCS = /correct\s*score/i.test(mk.name);
            const odds = isCS ? mk.odds.slice(0, 6) : mk.odds;
            return (
              <div key={mk.id} className="rounded-lg border border-border/50 bg-background/30 p-2">
                <div className="text-[10px] uppercase tracking-widest text-muted-foreground mb-1.5 flex items-center justify-between">
                  <span>{mk.name}</span>
                  {isCS && mk.odds.length > 6 && <span className="text-primary">+{mk.odds.length - 6} more</span>}
                </div>
                <div className={`grid gap-1.5 ${odds.length <= 3 ? "grid-cols-3" : "grid-cols-3 sm:grid-cols-6"}`}>
                  {odds.map((o) => (
                    <button
                      key={o.id}
                      disabled={locked || !mk.is_open}
                      onClick={() => setPickFor({ marketId: mk.id, marketName: mk.name, oddId: o.id, label: o.label, value: Number(o.value) })}
                      className={`px-1.5 py-1.5 rounded-md text-[11px] font-bold transition-all border ${
                        locked ? "bg-secondary/30 text-muted-foreground cursor-not-allowed border-transparent"
                        : "bg-secondary/40 border-border hover:border-primary/60 hover:bg-primary/10"
                      } ${o.is_winner === true ? "ring-1 ring-emerald-400" : ""}`}
                    >
                      <div className="text-[9px] uppercase tracking-wider opacity-80 truncate">{o.label}</div>
                      <div className="text-[12px]">{Number(o.value).toFixed(2)}</div>
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
          {markets.length === 0 && <Badge variant="outline" className="text-[10px]">No markets yet</Badge>}
        </div>
      )}

      {pickFor && (
        <InstantBetDialog
          match={match}
          marketName={pickFor.marketName}
          oddId={pickFor.oddId}
          label={pickFor.label}
          odds={pickFor.value}
          onClose={() => setPickFor(null)}
        />
      )}
    </Card>
  );
}

function InstantBetDialog({ match, marketName, oddId, label, odds, onClose }: {
  match: MatchRow; marketName: string; oddId: string; label: string; odds: number; onClose: () => void;
}) {
  const { user, profile, refresh } = useAuth();
  const nav = useNavigate();
  const [cfg, setCfg] = useState({ min: 100000, max: 10000000 });
  const [stake, setStake] = useState(100000);
  const [busy, setBusy] = useState(false);
  const balance = profile?.token_balance ?? 0;
  const payout = Math.floor(stake * odds);
  const overBalance = stake > balance;
  const belowMin = stake < cfg.min;
  const overMax = stake > cfg.max;

  useEffect(() => {
    supabase.from("app_settings").select("virtual_min_stake,virtual_max_stake").eq("id", 1).maybeSingle()
      .then(({ data }) => {
        if (data) {
          setCfg({ min: Number((data as any).virtual_min_stake ?? 100000), max: Number((data as any).virtual_max_stake ?? 10000000) });
          setStake(Number((data as any).virtual_min_stake ?? 100000));
        }
      });
  }, []);

  async function place() {
    if (!user) { nav({ to: "/login" }); return; }
    if (overBalance) return toast.error("Insufficient balance");
    if (belowMin) return toast.error(`Minimum stake is ${cfg.min.toLocaleString()}`);
    if (overMax) return toast.error(`Maximum stake is ${cfg.max.toLocaleString()}`);
    setBusy(true);
    const { data, error } = await supabase.rpc("place_virtual_bet", { _match_id: match.id, _odd_id: oddId, _stake: stake });
    setBusy(false);
    if (error) return toast.error(error.message);
    const res = data as any;
    toast.success(`Bet placed · ${res.tracking_id}`);
    refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent className="max-w-sm">
        <DialogHeader><DialogTitle>Instant bet · {marketName}</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div className="rounded-lg border border-primary/30 bg-primary/5 p-3">
            <div className="text-[10px] uppercase tracking-widest text-muted-foreground">{match.home_team?.name} vs {match.away_team?.name}</div>
            <div className="flex items-center justify-between mt-1">
              <Badge className="bg-accent/15 text-accent border-accent/30">{label}</Badge>
              <div className="font-mono font-black text-primary">{odds.toFixed(2)}</div>
            </div>
          </div>
          <div>
            <label className="text-xs uppercase tracking-widest text-muted-foreground">Stake</label>
            <Input type="number" value={stake} step={Math.max(10000, Math.floor(cfg.min/2))} min={cfg.min} max={cfg.max}
              onChange={(e) => setStake(Number(e.target.value))} className="h-11 font-bold text-lg" />
            <div className="flex gap-1 mt-1 flex-wrap">
              {[cfg.min, cfg.min*2, cfg.min*5, Math.min(balance, cfg.max)].filter((v, i, a) => v > 0 && a.indexOf(v) === i).map((v) => (
                <button key={v} onClick={() => setStake(v)} className="text-[10px] px-2 py-0.5 rounded-full bg-muted hover:bg-primary/20 border border-border">
                  {v === Math.min(balance, cfg.max) ? "MAX" : v.toLocaleString()}
                </button>
              ))}
            </div>
            <div className="flex justify-between text-[11px] text-muted-foreground mt-1">
              <span>Min {cfg.min.toLocaleString()} · Max {cfg.max.toLocaleString()}</span>
              <span>Balance: <b className={overBalance ? "text-destructive" : "text-primary"}>{balance.toLocaleString()}</b></span>
            </div>
          </div>
          <div className="rounded-lg border border-accent/30 bg-accent/5 p-3 flex items-center justify-between">
            <div>
              <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Potential payout</div>
              <div className="font-black text-xl text-accent flex items-center gap-1"><Coins className="h-4 w-4" />{payout.toLocaleString()}</div>
            </div>
          </div>
          {overBalance && <p className="text-[11px] text-destructive">Not enough tokens.</p>}
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button onClick={place} disabled={busy || overBalance || belowMin || overMax}>{busy ? "Placing…" : "Place bet"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
