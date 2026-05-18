import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Layout } from "@/components/Layout";
import { PageShell } from "@/components/PageShell";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Dice5, Lock, Flame, Trophy, Clock } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useBetSlip } from "@/contexts/BetSlipContext";
import { Countdown } from "@/components/Countdown";
import { TeamLogo } from "@/components/TeamLogo";
import type { MatchRow } from "@/lib/queries";

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
          <header className="text-center">
            <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-primary/15 border border-primary/40 text-[10px] uppercase tracking-[0.3em] text-primary mb-3">
              <Dice5 className="h-3.5 w-3.5" /> Instant Virtuals
            </div>
            <h1 className="text-3xl sm:text-5xl font-black gradient-gold-text">Gang vs Gang · Live Now</h1>
            <p className="text-muted-foreground mt-2 text-sm">Rapid-fire rounds. Pick your gang. Cash out instantly when results drop.</p>
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
  const { selections, add, remove } = useBetSlip();
  const home = match.home_team?.name ?? "Home";
  const away = match.away_team?.name ?? "Away";
  const lockTime = (match as any).lock_time as string | null;
  const [tick, setTick] = useState(0);
  useEffect(() => { const t = setInterval(() => setTick((n) => n + 1), 1000); return () => clearInterval(t); }, []);
  const isLockedByTime = lockTime ? new Date(lockTime).getTime() <= Date.now() : false;
  const locked = match.status !== "scheduled" || isLockedByTime;
  // Order markets: winner first, first blood, totals, correct score
  const order = (n: string) => /match\s*winner/i.test(n) ? 0 : /first\s*blood/i.test(n) ? 1 : /total|over\/under/i.test(n) ? 2 : /correct\s*score/i.test(n) ? 3 : 4;
  const markets = [...(match.markets ?? [])].sort((a, b) => order(a.name) - order(b.name));

  return (
    <Card className="glass p-4 relative overflow-hidden border-primary/30">
      <div className="absolute top-0 right-0 px-2 py-0.5 text-[10px] font-bold tracking-widest rounded-bl-md"
        style={{ background: locked ? "oklch(0.5 0.18 25)" : "oklch(0.55 0.18 158)", color: "white" }}>
        {locked ? "● LOCKED" : "● LIVE"}
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
          <Dice5 className="h-6 w-6 text-primary mx-auto animate-pulse" />
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
        {locked ? (
          <span className="text-destructive font-bold flex items-center justify-center gap-1">
            <Lock className="h-3 w-3" /> Round locked — drawing result…
          </span>
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
                  {odds.map((o) => {
                    const sel = selections.find((s) => s.odd_id === o.id);
                    return (
                      <button
                        key={o.id}
                        disabled={locked || !mk.is_open}
                        onClick={() => {
                          if (sel) { remove(o.id); return; }
                          add({
                            match_id: match.id,
                            match_name: `${home} vs ${away}`,
                            market_id: mk.id, market_name: mk.name,
                            odd_id: o.id, selection_label: isCS ? `Correct Score [${o.label}]` : o.label,
                            odds: Number(o.value),
                          });
                        }}
                        className={`px-1.5 py-1.5 rounded-md text-[11px] font-bold transition-all border ${
                          locked ? "bg-secondary/30 text-muted-foreground cursor-not-allowed border-transparent"
                          : sel ? "bg-primary text-primary-foreground border-transparent"
                          : "bg-secondary/40 border-border hover:border-primary/60"
                        }`}
                      >
                        <div className="text-[9px] uppercase tracking-wider opacity-80 truncate">{o.label}</div>
                        <div className="text-[12px]">{Number(o.value).toFixed(2)}</div>
                      </button>
                    );
                  })}
                </div>
              </div>
            );
          })}
          {markets.length === 0 && <Badge variant="outline" className="text-[10px]">No markets yet</Badge>}
        </div>
      )}
    </Card>
  );
}
