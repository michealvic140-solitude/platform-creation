import { Link } from "@tanstack/react-router";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Flame, Crosshair, Crown, ChevronDown } from "lucide-react";
import { useMemo, useState } from "react";
import type { MatchRow } from "@/lib/queries";
import { useBetSlip } from "@/contexts/BetSlipContext";
import { toast } from "sonner";
import { Countdown } from "@/components/Countdown";

// Group matches by gang_type of home_team (G = Gang, F = Free-agent/Shooter, null = Battle)
const GANG_TABS: { key: string; label: string; icon: any; match: (m: MatchRow) => boolean }[] = [
  { key: "all",     label: "All",           icon: Crosshair, match: () => true },
  { key: "gang",    label: "Gang Wars",     icon: Crosshair, match: (m) => m.home_team?.gang_type === "G" || m.away_team?.gang_type === "G" },
  { key: "shooter", label: "Solo Shooters", icon: Crown,     match: (m) => m.home_team?.gang_type === "F" || m.away_team?.gang_type === "F" },
  { key: "tourney", label: "Tournament",    icon: Flame,     match: (m) => m.match_kind === "future" },
];

function pick1x2(m: MatchRow) {
  const market = m.markets.find((mk) => /1x2|winner|match ?result|match ?winner|to win/i.test(mk.name)) || m.markets[0];
  if (!market) return null;
  const home = market.odds.find((o) => /^1$|home|shooter a|red/i.test(o.label)) ?? market.odds[0];
  const away = market.odds.find((o) => /^2$|away|shooter b|blue/i.test(o.label)) ?? market.odds[market.odds.length - 1];
  const draw = market.odds.find((o) => /^x$|draw|tie/i.test(o.label));
  return { market, home, draw, away };
}

function statusLabel(m: MatchRow) {
  if (m.status === "live") {
    const elapsed = Math.max(0, Math.floor((Date.now() - new Date(m.start_time).getTime()) / 60000));
    return `${Math.min(90, elapsed)}'`;
  }
  const d = new Date(m.start_time);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
}

function Row({ m, live }: { m: MatchRow; live?: boolean }) {
  const picks = pick1x2(m);
  const { selections, add, remove } = useBetSlip();
  const homeName = m.home_team?.name ?? m.home_player?.name ?? "Home";
  const awayName = m.away_team?.name ?? m.away_player?.name ?? "Away";

  const toggle = (od: any) => {
    if (!od || !picks) return;
    if (selections.some((s) => s.odd_id === od.id)) { remove(od.id); return; }
    if (!picks.market.is_open || m.status === "ended") { toast.error("Market closed."); return; }
    add({ match_id: m.id, match_name: m.name, market_id: picks.market.id, market_name: picks.market.name, odd_id: od.id, selection_label: od.label, odds: Number(od.value) });
  };

  const OddBtn = ({ od }: { od: any | undefined }) => {
    if (!od) return <div className="h-9 rounded bg-muted/30" />;
    const sel = selections.some((s) => s.odd_id === od.id);
    return (
      <button
        onClick={() => toggle(od)}
        className={`h-9 w-full text-xs font-black rounded transition tabular-nums
          ${sel ? "bg-primary text-primary-foreground ring-2 ring-primary" : "bg-emerald-600/85 hover:bg-emerald-500 text-white"}`}
      >
        {Number(od.value).toFixed(2)}
      </button>
    );
  };

  return (
    <div className="grid grid-cols-[52px_1fr_auto_auto_auto_auto] items-center gap-1.5 px-2 py-2 border-b border-border/40 hover:bg-primary/[0.03]">
      <div className="text-[11px] font-bold tabular-nums text-center">
        {live ? <span className="text-destructive animate-pulse">{statusLabel(m)}</span> : <span className="text-muted-foreground">{statusLabel(m)}</span>}
      </div>
      <Link to="/matches/$matchId" params={{ matchId: m.id }} className="min-w-0 hover:text-primary">
        <div className="text-xs font-semibold truncate leading-tight">{homeName}</div>
        <div className="text-xs font-semibold truncate leading-tight">{awayName}</div>
      </Link>
      <div className="text-[10px] tabular-nums text-center min-w-[26px]">
        {live ? (
          <div className="text-primary font-bold leading-tight">
            <div>{m.home_score}</div>
            <div>{m.away_score}</div>
          </div>
        ) : (
          <div className="text-muted-foreground text-[9px] leading-tight">
            <div>-</div>
            <div>-</div>
          </div>
        )}
      </div>
      <div className="w-12"><OddBtn od={picks?.home} /></div>
      <div className="w-12"><OddBtn od={picks?.draw} /></div>
      <div className="w-12"><OddBtn od={picks?.away} /></div>
    </div>
  );
}

function TabHeader({ tabs, active, onSelect }: { tabs: typeof GANG_TABS; active: string; onSelect: (k: string) => void }) {
  return (
    <div className="flex items-center gap-1 px-2 pt-2 pb-1 overflow-x-auto scrollbar-hide">
      {tabs.map((t) => {
        const on = t.key === active;
        return (
          <button key={t.key} onClick={() => onSelect(t.key)}
            className={`flex flex-col items-center gap-0.5 px-3 py-1 shrink-0 border-b-2 transition ${on ? "border-primary text-primary" : "border-transparent text-muted-foreground hover:text-foreground"}`}>
            <t.icon className="h-4 w-4" />
            <span className="text-[10px] font-bold tracking-wide">{t.label}</span>
          </button>
        );
      })}
    </div>
  );
}

function ColumnHeader() {
  return (
    <div className="grid grid-cols-[52px_1fr_auto_auto_auto_auto] items-center gap-1.5 px-2 py-1.5 border-b border-primary/30 bg-card/60 text-[10px] font-bold text-muted-foreground uppercase tracking-widest">
      <div>Time</div>
      <div>Shooters</div>
      <div></div>
      <div className="w-12 text-center">1</div>
      <div className="w-12 text-center">X</div>
      <div className="w-12 text-center">2</div>
    </div>
  );
}

export function LiveHighlightsTable({ matches }: { matches: MatchRow[] }) {
  const [tab, setTab] = useState("all");
  const filtered = useMemo(() => matches.filter(GANG_TABS.find((t) => t.key === tab)!.match).slice(0, 20), [matches, tab]);

  return (
    <Card className="glass overflow-hidden border-destructive/30">
      <div className="flex items-center justify-between px-3 py-2 border-b border-destructive/30 bg-destructive/5">
        <div className="flex items-center gap-2">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full rounded-full bg-destructive opacity-75 animate-ping" />
            <span className="relative inline-flex rounded-full h-2 w-2 bg-destructive" />
          </span>
          <span className="text-sm font-black tracking-wider text-destructive">LIVE SHOOTOUTS</span>
        </div>
        <Link to="/matches" className="text-[10px] uppercase tracking-widest text-primary hover:underline">View all →</Link>
      </div>
      <TabHeader tabs={GANG_TABS} active={tab} onSelect={setTab} />
      <ColumnHeader />
      {filtered.length === 0 ? (
        <div className="p-6 text-center text-xs text-muted-foreground">No live shootouts. Check the highlights below.</div>
      ) : (
        filtered.map((m) => <Row key={m.id} m={m} live />)
      )}
    </Card>
  );
}

export function HighlightsTable({ matches }: { matches: MatchRow[] }) {
  const [tab, setTab] = useState("all");
  const filtered = useMemo(() => matches.filter(GANG_TABS.find((t) => t.key === tab)!.match), [matches, tab]);

  // Group by date (Today / Tomorrow / dayname)
  const groups = useMemo(() => {
    const g: Record<string, { label: string; items: MatchRow[]; ts: number }> = {};
    const now = new Date();
    const today = now.toDateString();
    const tomorrow = new Date(now.getTime() + 86400000).toDateString();
    for (const m of filtered) {
      const d = new Date(m.start_time);
      const k = d.toDateString();
      let label: string;
      if (k === today) label = "Today";
      else if (k === tomorrow) label = "Tomorrow";
      else label = d.toLocaleDateString([], { weekday: "short", day: "2-digit", month: "short" });
      if (!g[k]) g[k] = { label, items: [], ts: d.getTime() };
      g[k].items.push(m);
    }
    return Object.entries(g).sort((a, b) => a[1].ts - b[1].ts);
  }, [filtered]);

  return (
    <Card className="glass overflow-hidden border-primary/30 mt-4">
      <div className="flex items-center justify-between px-3 py-2 border-b border-primary/30 bg-primary/5">
        <div className="flex items-center gap-2">
          <Flame className="h-4 w-4 text-primary" />
          <span className="text-sm font-black tracking-wider text-primary">HIGHLIGHTS</span>
        </div>
        <Link to="/matches" className="text-[10px] uppercase tracking-widest text-primary hover:underline">View highlights →</Link>
      </div>
      <TabHeader tabs={GANG_TABS} active={tab} onSelect={setTab} />
      {groups.length === 0 ? (
        <div className="p-6 text-center text-xs text-muted-foreground">No upcoming shootouts scheduled.</div>
      ) : (
        groups.map(([k, g]) => (
          <div key={k}>
            <div className="flex items-center justify-between px-3 py-1.5 bg-muted/20 border-b border-border/40">
              <span className="text-[11px] font-bold text-foreground">{g.label}</span>
              <Badge variant="outline" className="text-[9px] px-1.5 py-0 h-4 border-primary/30 text-muted-foreground">1X2</Badge>
            </div>
            <ColumnHeader />
            {g.items.slice(0, 30).map((m) => <Row key={m.id} m={m} />)}
          </div>
        ))
      )}
    </Card>
  );
}
