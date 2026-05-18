import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from "@/components/ui/dialog";
import { Dice5, Plus, Lock, Trophy, Trash2, RefreshCw } from "lucide-react";
import { toast } from "sonner";

const DEFAULT_SCORES = ["0:0", "1:0", "0:1", "1:1", "2:0", "0:2", "2:1", "1:2", "2:2", "3:0", "0:3", "3:1", "1:3", "3:2", "2:3", "3:3"];

type GangOpt = { name: string };
type Round = {
  id: string; name: string; status: string; start_time: string; lock_time: string | null;
  home_team_id: string; away_team_id: string;
  home_score: number; away_score: number; virtual_first_blood_team_id: string | null;
  home_team: { id: string; name: string } | null;
  away_team: { id: string; name: string } | null;
};

export function VirtualAdminPanel() {
  const [gangs, setGangs] = useState<GangOpt[]>([]);
  const [rounds, setRounds] = useState<Round[]>([]);
  const [composerOpen, setComposerOpen] = useState(false);
  const [resolveOf, setResolveOf] = useState<Round | null>(null);

  const reload = async () => {
    const { data: profs } = await supabase.from("profiles").select("gang_name").not("gang_name", "is", null);
    const names = Array.from(new Set((profs ?? []).map((p: any) => p.gang_name).filter(Boolean))).sort();
    setGangs(names.map((name) => ({ name })));
    const { data: rs } = await supabase
      .from("matches")
      .select("id,name,status,start_time,lock_time,home_team_id,away_team_id,home_score,away_score,virtual_first_blood_team_id,home_team:teams!home_team_id(id,name),away_team:teams!away_team_id(id,name)")
      .eq("is_virtual", true)
      .order("start_time", { ascending: false })
      .limit(50);
    setRounds((rs ?? []) as any);
  };

  useEffect(() => {
    reload();
    const ch = supabase.channel("admin-virtual")
      .on("postgres_changes", { event: "*", schema: "public", table: "matches", filter: "is_virtual=eq.true" }, reload)
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, []);

  async function quickCreate() {
    if (gangs.length < 2) return toast.error("Need at least 2 registered gangs");
    const a = gangs[Math.floor(Math.random() * gangs.length)];
    let b = gangs[Math.floor(Math.random() * gangs.length)];
    while (b.name === a.name) b = gangs[Math.floor(Math.random() * gangs.length)];
    await createRound({ gangA: a.name, gangB: b.name, startInSec: 5, lockInSec: 35, oddsA: 1.95, oddsDraw: 3.5, oddsB: 1.95, totalLine: 4.5, oddsOver: 1.85, oddsUnder: 1.85, oddsFirstA: 1.95, oddsFirstB: 1.95, csOdds: 7, includeWinner: true, includeFirstBlood: true, includeTotal: true, includeCS: true });
    toast.success("Round created");
  }

  return (
    <div className="space-y-4">
      <Card className="glass p-4">
        <div className="flex items-center justify-between gap-3 flex-wrap">
          <div>
            <h3 className="text-lg font-black flex items-center gap-2"><Dice5 className="h-5 w-5 text-primary" /> Virtual Gangs · Instant Rounds</h3>
            <p className="text-xs text-muted-foreground">Create, lock and resolve gang-vs-gang virtual matches.</p>
          </div>
          <div className="flex gap-2">
            <Button size="sm" variant="outline" onClick={reload}><RefreshCw className="h-3 w-3 mr-1" />Refresh</Button>
            <Button size="sm" variant="outline" onClick={quickCreate}><Dice5 className="h-3 w-3 mr-1" />Quick Round</Button>
            <Button size="sm" onClick={() => setComposerOpen(true)}><Plus className="h-3 w-3 mr-1" />New Round</Button>
          </div>
        </div>
      </Card>

      <Card className="glass p-4">
        <div className="text-xs uppercase tracking-widest text-muted-foreground mb-2">Rounds ({rounds.length})</div>
        <div className="space-y-2 max-h-[500px] overflow-y-auto">
          {rounds.length === 0 && <p className="text-sm text-muted-foreground">No virtual rounds yet.</p>}
          {rounds.map((r) => {
            const lockMs = r.lock_time ? new Date(r.lock_time).getTime() : 0;
            const isLockedByTime = lockMs && lockMs <= Date.now();
            const tone = r.status === "ended" ? "bg-emerald-500/15 border-emerald-500/40 text-emerald-400"
              : isLockedByTime || r.status === "live" ? "bg-destructive/15 border-destructive/40 text-destructive"
              : "bg-primary/15 border-primary/40 text-primary";
            return (
              <div key={r.id} className="flex items-center justify-between gap-3 rounded-md border border-border bg-background/40 p-2.5">
                <div className="min-w-0 flex-1">
                  <div className="text-sm font-bold truncate">{r.home_team?.name} vs {r.away_team?.name}</div>
                  <div className="text-[10px] text-muted-foreground">{new Date(r.start_time).toLocaleString()} · {r.status} {r.status === "ended" && <span className="text-emerald-400">· final {r.home_score}-{r.away_score}</span>}</div>
                </div>
                <Badge variant="outline" className={tone}>{r.status === "ended" ? "RESOLVED" : isLockedByTime ? "LOCKED" : "OPEN"}</Badge>
                <div className="flex gap-1">
                  {r.status !== "ended" && (
                    <>
                      <Button size="sm" variant="outline" onClick={async () => {
                        await supabase.from("matches").update({ lock_time: new Date().toISOString(), status: "live" }).eq("id", r.id);
                        toast.success("Locked");
                      }}><Lock className="h-3 w-3 mr-1" />Lock</Button>
                      <Button size="sm" onClick={() => setResolveOf(r)}><Trophy className="h-3 w-3 mr-1" />Resolve</Button>
                    </>
                  )}
                  <Button size="sm" variant="ghost" onClick={async () => {
                    if (!confirm("Delete this round?")) return;
                    await supabase.from("markets").delete().eq("match_id", r.id);
                    await supabase.from("matches").delete().eq("id", r.id);
                    toast.success("Deleted");
                  }}><Trash2 className="h-3 w-3" /></Button>
                </div>
              </div>
            );
          })}
        </div>
      </Card>

      {composerOpen && <ComposerDialog gangs={gangs} onClose={() => setComposerOpen(false)} onSave={createRound} />}
      {resolveOf && <ResolveDialog round={resolveOf} onClose={() => setResolveOf(null)} />}
    </div>
  );
}

type Cfg = {
  gangA: string; gangB: string;
  startInSec: number; lockInSec: number;
  oddsA: number; oddsDraw: number; oddsB: number;
  oddsFirstA: number; oddsFirstB: number;
  totalLine: number; oddsOver: number; oddsUnder: number;
  csOdds: number;
  includeWinner: boolean; includeFirstBlood: boolean; includeTotal: boolean; includeCS: boolean;
};

async function ensureTeam(name: string): Promise<string> {
  const { data: existing } = await supabase.from("teams").select("id").eq("name", name).maybeSingle();
  if (existing) return existing.id;
  const { data: created, error } = await supabase.from("teams").insert({ name }).select("id").single();
  if (error) throw error;
  return created.id;
}

async function getVirtualCategoryId(): Promise<string | null> {
  const { data } = await supabase.from("categories").select("id").eq("name", "Virtual Gangs").maybeSingle();
  return data?.id ?? null;
}

async function createRound(cfg: Cfg) {
  const homeId = await ensureTeam(cfg.gangA);
  const awayId = await ensureTeam(cfg.gangB);
  const catId = await getVirtualCategoryId();
  const start = new Date(Date.now() + cfg.startInSec * 1000);
  const lock = new Date(Date.now() + cfg.lockInSec * 1000);
  const { data: match, error } = await supabase.from("matches").insert({
    name: `${cfg.gangA} vs ${cfg.gangB}`,
    home_team_id: homeId, away_team_id: awayId,
    start_time: start.toISOString(), lock_time: lock.toISOString(),
    status: "scheduled", is_virtual: true,
    category_id: catId,
  }).select("id").single();
  if (error) throw error;
  const matchId = match.id;

  if (cfg.includeWinner) {
    const { data: mk } = await supabase.from("markets").insert({ match_id: matchId, name: "Match Winner" }).select("id").single();
    if (mk) await supabase.from("odds").insert([
      { market_id: mk.id, label: cfg.gangA, value: cfg.oddsA },
      { market_id: mk.id, label: "Draw", value: cfg.oddsDraw },
      { market_id: mk.id, label: cfg.gangB, value: cfg.oddsB },
    ]);
  }
  if (cfg.includeFirstBlood) {
    const { data: mk } = await supabase.from("markets").insert({ match_id: matchId, name: "First Blood" }).select("id").single();
    if (mk) await supabase.from("odds").insert([
      { market_id: mk.id, label: cfg.gangA, value: cfg.oddsFirstA },
      { market_id: mk.id, label: cfg.gangB, value: cfg.oddsFirstB },
    ]);
  }
  if (cfg.includeTotal) {
    const { data: mk } = await supabase.from("markets").insert({ match_id: matchId, name: `Total Kills O/U ${cfg.totalLine}` }).select("id").single();
    if (mk) await supabase.from("odds").insert([
      { market_id: mk.id, label: `Over ${cfg.totalLine}`, value: cfg.oddsOver },
      { market_id: mk.id, label: `Under ${cfg.totalLine}`, value: cfg.oddsUnder },
    ]);
  }
  if (cfg.includeCS) {
    const { data: mk } = await supabase.from("markets").insert({ match_id: matchId, name: "Correct Score" }).select("id").single();
    if (mk) await supabase.from("odds").insert(DEFAULT_SCORES.map((s) => ({ market_id: mk.id, label: s, value: cfg.csOdds })));
  }
}

function ComposerDialog({ gangs, onClose, onSave }: { gangs: GangOpt[]; onClose: () => void; onSave: (c: Cfg) => Promise<void> }) {
  const [cfg, setCfg] = useState<Cfg>({
    gangA: gangs[0]?.name ?? "", gangB: gangs[1]?.name ?? "",
    startInSec: 5, lockInSec: 35,
    oddsA: 1.95, oddsDraw: 3.5, oddsB: 1.95,
    oddsFirstA: 1.95, oddsFirstB: 1.95,
    totalLine: 4.5, oddsOver: 1.85, oddsUnder: 1.85,
    csOdds: 7,
    includeWinner: true, includeFirstBlood: true, includeTotal: true, includeCS: true,
  });
  const upd = <K extends keyof Cfg>(k: K, v: Cfg[K]) => setCfg((c) => ({ ...c, [k]: v }));

  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
        <DialogHeader><DialogTitle>New Virtual Round</DialogTitle></DialogHeader>
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <div><Label>Gang A</Label>
              <Select value={cfg.gangA} onValueChange={(v) => upd("gangA", v)}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>{gangs.map((g) => <SelectItem key={g.name} value={g.name}>{g.name}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div><Label>Gang B</Label>
              <Select value={cfg.gangB} onValueChange={(v) => upd("gangB", v)}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>{gangs.map((g) => <SelectItem key={g.name} value={g.name}>{g.name}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div><Label>Start in (sec)</Label><Input type="number" value={cfg.startInSec} onChange={(e) => upd("startInSec", +e.target.value)} /></div>
            <div><Label>Lock at (sec from now)</Label><Input type="number" value={cfg.lockInSec} onChange={(e) => upd("lockInSec", +e.target.value)} /></div>
          </div>

          <MarketBlock label="Match Winner" enabled={cfg.includeWinner} onToggle={(v) => upd("includeWinner", v)}>
            <NumIn label={`${cfg.gangA || "Home"}`} v={cfg.oddsA} on={(v) => upd("oddsA", v)} />
            <NumIn label="Draw" v={cfg.oddsDraw} on={(v) => upd("oddsDraw", v)} />
            <NumIn label={`${cfg.gangB || "Away"}`} v={cfg.oddsB} on={(v) => upd("oddsB", v)} />
          </MarketBlock>

          <MarketBlock label="First Blood" enabled={cfg.includeFirstBlood} onToggle={(v) => upd("includeFirstBlood", v)}>
            <NumIn label={`${cfg.gangA || "A"}`} v={cfg.oddsFirstA} on={(v) => upd("oddsFirstA", v)} />
            <NumIn label={`${cfg.gangB || "B"}`} v={cfg.oddsFirstB} on={(v) => upd("oddsFirstB", v)} />
          </MarketBlock>

          <MarketBlock label="Total Kills O/U" enabled={cfg.includeTotal} onToggle={(v) => upd("includeTotal", v)}>
            <NumIn label="Line" v={cfg.totalLine} on={(v) => upd("totalLine", v)} step={0.5} />
            <NumIn label="Over" v={cfg.oddsOver} on={(v) => upd("oddsOver", v)} />
            <NumIn label="Under" v={cfg.oddsUnder} on={(v) => upd("oddsUnder", v)} />
          </MarketBlock>

          <MarketBlock label="Correct Score (16 scorelines)" enabled={cfg.includeCS} onToggle={(v) => upd("includeCS", v)}>
            <NumIn label="Flat odds per scoreline" v={cfg.csOdds} on={(v) => upd("csOdds", v)} />
          </MarketBlock>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button onClick={async () => {
            if (!cfg.gangA || !cfg.gangB) return toast.error("Pick two gangs");
            if (cfg.gangA === cfg.gangB) return toast.error("Gangs must differ");
            try { await onSave(cfg); toast.success("Round created"); onClose(); }
            catch (e: any) { toast.error(e.message); }
          }}>Create</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function MarketBlock({ label, enabled, onToggle, children }: { label: string; enabled: boolean; onToggle: (v: boolean) => void; children: any }) {
  return (
    <div className="rounded-lg border border-border p-3 bg-background/30">
      <div className="flex items-center justify-between mb-2">
        <div className="text-sm font-bold">{label}</div>
        <Switch checked={enabled} onCheckedChange={onToggle} />
      </div>
      {enabled && <div className="grid grid-cols-3 gap-2">{children}</div>}
    </div>
  );
}

function NumIn({ label, v, on, step = 0.05 }: { label: string; v: number; on: (n: number) => void; step?: number }) {
  return (
    <div><Label className="text-[10px] uppercase tracking-widest text-muted-foreground">{label}</Label>
      <Input type="number" step={step} value={v} onChange={(e) => on(+e.target.value)} /></div>
  );
}

function ResolveDialog({ round, onClose }: { round: Round; onClose: () => void }) {
  const [home, setHome] = useState(0);
  const [away, setAway] = useState(0);
  const [first, setFirst] = useState<string>(round.home_team_id);
  const [busy, setBusy] = useState(false);

  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent>
        <DialogHeader><DialogTitle>Resolve · {round.home_team?.name} vs {round.away_team?.name}</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div className="grid grid-cols-2 gap-3">
            <div><Label>{round.home_team?.name} score</Label><Input type="number" min={0} value={home} onChange={(e) => setHome(+e.target.value)} /></div>
            <div><Label>{round.away_team?.name} score</Label><Input type="number" min={0} value={away} onChange={(e) => setAway(+e.target.value)} /></div>
          </div>
          <div>
            <Label>First blood</Label>
            <Select value={first} onValueChange={setFirst}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value={round.home_team_id}>{round.home_team?.name}</SelectItem>
                <SelectItem value={round.away_team_id}>{round.away_team?.name}</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <p className="text-[11px] text-muted-foreground">This marks winning odds across all markets, ends the match, and credits winning tickets.</p>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button disabled={busy} onClick={async () => {
            setBusy(true);
            const { error } = await supabase.rpc("resolve_virtual_round", {
              _match_id: round.id, _home_score: home, _away_score: away, _first_blood_team_id: first,
            });
            setBusy(false);
            if (error) return toast.error(error.message);
            toast.success("Resolved & payouts credited");
            onClose();
          }}>Publish Result</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
