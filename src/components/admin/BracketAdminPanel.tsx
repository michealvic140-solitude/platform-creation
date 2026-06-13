import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from "@/components/ui/dialog";
import { toast } from "sonner";
import { useConfirm } from "@/components/ConfirmDialog";
import { Crosshair, Plus, Trash2, Trophy, Upload, Check, X, Image as ImageIcon, ExternalLink, Search } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command";

type Tournament = {
  id: string; name: string; tagline: string | null; banner_url: string | null;
  size: number; status: string; starts_at: string | null; champion_participant_id: string | null;
};
type Participant = {
  id: string; tournament_id: string; player_id: string | null; team_id: string | null;
  display_name: string; gang_tag: string | null; emblem_url: string | null; seed: number | null;
  is_eliminated: boolean; eliminated_at_round: string | null;
};
type Match = {
  id: string; tournament_id: string; round: string; slot_index: number; code: string;
  participant_a_id: string | null; participant_b_id: string | null;
  kills_a: number | null; kills_b: number | null;
  winner_id: string | null; loser_id: string | null; status: string;
};

const ROUND_LABELS: Record<string, string> = {
  opening: "OPENING ROUND",
  r16: "ROUND OF 16",
  qf: "QUARTERFINALS",
  sf: "SEMIFINALS",
  final: "GRAND FINAL",
};

export function BracketAdminPanel() {
  const [tournaments, setTournaments] = useState<Tournament[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);

  async function load() {
    const { data } = await supabase.from("tournaments").select("*").order("created_at", { ascending: false });
    setTournaments((data ?? []) as Tournament[]);
    if (!activeId && data && data.length > 0) setActiveId(data[0].id);
  }
  useEffect(() => { load(); }, []);

  useEffect(() => {
    const ch = supabase.channel("admin-tournaments")
      .on("postgres_changes", { event: "*", schema: "public", table: "tournaments" }, load)
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, []);

  const active = useMemo(() => tournaments.find((t) => t.id === activeId) ?? null, [tournaments, activeId]);

  return (
    <div className="space-y-4">
      <Card className="glass p-4 space-y-3">
        <div className="flex items-center gap-2 flex-wrap">
          <Crosshair className="h-5 w-5 text-primary" />
          <div className="font-bold text-lg">Knockout Bracket Tournaments</div>
          <Badge variant="outline" className="border-primary/40 text-primary ml-auto">
            {tournaments.length} tournament{tournaments.length === 1 ? "" : "s"}
          </Badge>
          <Button size="sm" className="btn-luxury" onClick={() => setCreating(true)}>
            <Plus className="h-4 w-4 mr-1" />New Tournament
          </Button>
        </div>
        <div className="flex flex-wrap gap-2">
          {tournaments.map((t) => (
            <button key={t.id} onClick={() => setActiveId(t.id)}
              className={`px-3 py-1.5 rounded-lg text-xs font-bold border transition ${
                activeId === t.id ? "bg-primary text-primary-foreground border-primary" : "border-border bg-muted/40 hover:border-primary/40"
              }`}>
              {t.name} <span className="opacity-70">· {t.size}P · {t.status}</span>
            </button>
          ))}
          {tournaments.length === 0 && <div className="text-xs text-muted-foreground">No tournaments yet. Create one to get started.</div>}
        </div>
      </Card>

      {creating && <CreateTournamentDialog open={creating} onClose={() => setCreating(false)} onCreated={(id) => { setActiveId(id); load(); }} />}

      {active && <TournamentEditor tournament={active} onChanged={load} />}
    </div>
  );
}

function CreateTournamentDialog({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: (id: string) => void }) {
  const [name, setName] = useState("LSL Knockout Bracket");
  const [size, setSize] = useState<number>(26);
  const [tagline, setTagline] = useState("ONE LEAGUE. NO MERCY. RESPECT THE GAME.");
  const [busy, setBusy] = useState(false);

  async function go() {
    if (!name.trim()) { toast.error("Tournament name is required"); return; }
    setBusy(true);
    const { data, error } = await supabase.from("tournaments").insert({
      name: name.trim(), size, tagline, status: "active",
    }).select().single();
    if (error) { setBusy(false); toast.error(error.message); return; }
    const { error: ge } = await (supabase as any).rpc("tournament_generate_bracket", { _tournament_id: data.id });
    setBusy(false);
    if (ge) { toast.error("Created but failed to generate bracket: " + ge.message); }
    else { toast.success("Tournament created"); onCreated(data.id); onClose(); }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent>
        <DialogHeader><DialogTitle>Create Knockout Tournament</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div>
            <label className="text-xs uppercase tracking-widest text-muted-foreground">Tournament Name</label>
            <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Season 1 Knockout" />
          </div>
          <div>
            <label className="text-xs uppercase tracking-widest text-muted-foreground">Tagline (shown under the title)</label>
            <Input value={tagline} onChange={(e) => setTagline(e.target.value)} />
          </div>
          <div>
            <label className="text-xs uppercase tracking-widest text-muted-foreground">Bracket Size (Number of Shooters)</label>
            <Select value={String(size)} onValueChange={(v) => setSize(Number(v))}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="8">8 Shooters (QF → SF → Final)</SelectItem>
                <SelectItem value="16">16 Shooters (R16 → QF → SF → Final)</SelectItem>
                <SelectItem value="26">26 Shooters (Opening → R16 → QF → SF → Final)</SelectItem>
                <SelectItem value="32">32 Shooters (Opening → R16 → QF → SF → Final)</SelectItem>
              </SelectContent>
            </Select>
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button className="btn-luxury" disabled={busy} onClick={go}>{busy ? "Creating…" : "Create & Generate Bracket"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function TournamentEditor({ tournament, onChanged }: { tournament: Tournament; onChanged: () => void }) {
  const [participants, setParticipants] = useState<Participant[]>([]);
  const [matches, setMatches] = useState<Match[]>([]);
  const [shooters, setShooters] = useState<any[]>([]);
  const confirm = useConfirm();

  async function loadAll() {
    const [{ data: p }, { data: m }, { data: pl }] = await Promise.all([
      supabase.from("tournament_participants").select("*").eq("tournament_id", tournament.id).order("seed", { ascending: true, nullsFirst: false }),
      supabase.from("tournament_matches").select("*").eq("tournament_id", tournament.id).order("round").order("slot_index"),
      supabase.from("players").select("id,name,team_id,teams:teams(name)").order("name"),
    ]);
    setParticipants((p ?? []) as Participant[]);
    setMatches((m ?? []) as Match[]);
    setShooters(pl ?? []);
  }

  useEffect(() => { loadAll(); }, [tournament.id]);

  useEffect(() => {
    const ch = supabase.channel(`bracket-admin-${tournament.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "tournament_matches", filter: `tournament_id=eq.${tournament.id}` }, loadAll)
      .on("postgres_changes", { event: "*", schema: "public", table: "tournament_participants", filter: `tournament_id=eq.${tournament.id}` }, loadAll)
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [tournament.id]);

  async function uploadBanner(file: File) {
    const path = `${tournament.id}/${Date.now()}_${file.name}`;
    const { error: ue } = await supabase.storage.from("event-banners").upload(path, file, { upsert: true });
    if (ue) { toast.error("Upload failed: " + ue.message); return; }
    const { data: signed } = await supabase.storage.from("event-banners").createSignedUrl(path, 60 * 60 * 24 * 365);
    if (!signed?.signedUrl) { toast.error("Could not create banner URL"); return; }
    await supabase.from("tournaments").update({ banner_url: signed.signedUrl }).eq("id", tournament.id);
    toast.success("Banner uploaded");
    onChanged();
  }

  async function deleteTournament() {
    const ok = await confirm({ title: "Delete tournament?", description: "This permanently removes the bracket and all participants. Cannot be undone.", confirmText: "Delete" });
    if (!ok) return;
    const { error } = await supabase.from("tournaments").delete().eq("id", tournament.id);
    if (error) toast.error(error.message); else { toast.success("Tournament deleted"); onChanged(); }
  }

  async function regenBracket() {
    const ok = await confirm({ title: "Regenerate bracket?", description: "This clears all existing matches and creates fresh empty slots. Participants are kept.", confirmText: "Regenerate" });
    if (!ok) return;
    const { error } = await (supabase as any).rpc("tournament_generate_bracket", { _tournament_id: tournament.id });
    if (error) toast.error(error.message); else { toast.success("Bracket regenerated"); loadAll(); }
  }

  async function addParticipant(playerId: string) {
    const player = shooters.find((s) => s.id === playerId);
    if (!player) return;
    const teamName = player.teams?.name ?? null;
    const { error } = await supabase.from("tournament_participants").insert({
      tournament_id: tournament.id,
      player_id: player.id,
      team_id: player.team_id,
      display_name: player.name,
      gang_tag: teamName,
      seed: participants.length + 1,
    });
    if (error) toast.error(error.message); else { toast.success(`${player.name} added`); loadAll(); }
  }

  async function removeParticipant(pid: string) {
    const ok = await confirm({ title: "Remove participant?", confirmText: "Remove" });
    if (!ok) return;
    await supabase.from("tournament_participants").delete().eq("id", pid);
    loadAll();
  }

  // Group matches by round for editing
  const byRound = useMemo(() => {
    const o: Record<string, Match[]> = { opening: [], r16: [], qf: [], sf: [], final: [] };
    for (const m of matches) o[m.round]?.push(m);
    return o;
  }, [matches]);

  return (
    <div className="space-y-4">
      {/* Tournament settings card */}
      <Card className="glass p-4 space-y-3">
        <div className="flex items-center gap-2 flex-wrap">
          <Trophy className="h-5 w-5 text-primary" />
          <div className="font-bold text-lg">{tournament.name}</div>
          <Badge variant="outline" className="border-primary/40 text-primary">{tournament.size} shooters</Badge>
          <Badge variant="outline" className={
            tournament.status === "completed" ? "border-emerald-400/40 text-emerald-400" :
            tournament.status === "active" ? "border-amber-400/40 text-amber-400" :
            "border-muted-foreground/40 text-muted-foreground"
          }>{tournament.status}</Badge>
          <div className="ml-auto flex gap-2">
            <Button size="sm" variant="outline" onClick={regenBracket}>Regenerate Bracket</Button>
            <Button size="sm" variant="destructive" onClick={deleteTournament}><Trash2 className="h-4 w-4 mr-1" />Delete</Button>
            <Link to="/tournament/$id" params={{ id: tournament.id }} className="inline-flex items-center gap-1 text-xs font-bold rounded-lg px-3 py-1.5 bg-gradient-gold text-primary-foreground">
              <ExternalLink className="h-3.5 w-3.5" />View Public
            </Link>
          </div>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div>
            <label className="text-xs uppercase tracking-widest text-muted-foreground">Banner Image (uploads to event-banners)</label>
            <div className="flex items-center gap-2 mt-1">
              <input type="file" accept="image/*" onChange={(e) => e.target.files?.[0] && uploadBanner(e.target.files[0])}
                className="text-xs file:mr-2 file:rounded file:border-0 file:bg-primary file:text-primary-foreground file:px-3 file:py-1.5 file:cursor-pointer" />
              {tournament.banner_url && <a href={tournament.banner_url} target="_blank" rel="noreferrer" className="text-xs text-primary underline inline-flex items-center gap-1"><ImageIcon className="h-3 w-3" />View</a>}
            </div>
          </div>
        </div>
      </Card>

      {/* Participants */}
      <Card className="glass p-4 space-y-3">
        <div className="flex items-center gap-2 flex-wrap">
          <div className="font-bold">Seeded Shooters <span className="text-muted-foreground text-xs">(from Clans → Shooters)</span></div>
          <Badge variant="outline" className="border-primary/40 text-primary ml-auto">{participants.length} / {tournament.size}</Badge>
        </div>
        <ShooterSearchPicker
          shooters={shooters.filter((s) => !participants.some((p) => p.player_id === s.id))}
          onPick={addParticipant}
        />
        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="text-[10px] uppercase tracking-widest text-muted-foreground border-b border-border">
                <th className="text-left py-2 px-2">SEED #</th>
                <th className="text-left py-2 px-2">SHOOTER NAME</th>
                <th className="text-left py-2 px-2">GANG / FACTION</th>
                <th className="text-left py-2 px-2">STATUS</th>
                <th className="text-left py-2 px-2">ACTION</th>
              </tr>
            </thead>
            <tbody>
              {participants.map((p) => (
                <tr key={p.id} className="border-b border-border/40">
                  <td className="py-2 px-2 font-mono">{p.seed ?? "—"}</td>
                  <td className="py-2 px-2 font-bold">{p.display_name}</td>
                  <td className="py-2 px-2 text-muted-foreground">{p.gang_tag || "—"}</td>
                  <td className="py-2 px-2">
                    {p.is_eliminated
                      ? <Badge variant="outline" className="border-red-400/40 text-red-400">Eliminated · {p.eliminated_at_round?.toUpperCase()}</Badge>
                      : <Badge variant="outline" className="border-emerald-400/40 text-emerald-400">Active</Badge>}
                  </td>
                  <td className="py-2 px-2">
                    <Button size="sm" variant="ghost" onClick={() => removeParticipant(p.id)}><X className="h-4 w-4" /></Button>
                  </td>
                </tr>
              ))}
              {participants.length === 0 && (
                <tr><td colSpan={5} className="py-3 text-center text-muted-foreground">No participants yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>

      {/* Round-by-round match editor */}
      {(["opening", "r16", "qf", "sf", "final"] as const).map((round) => {
        const list = byRound[round] || [];
        if (list.length === 0) return null;
        return (
          <Card key={round} className="glass p-4 space-y-3">
            <div className="font-bold text-sm tracking-widest text-primary">{ROUND_LABELS[round]}</div>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="text-[10px] uppercase tracking-widest text-muted-foreground border-b border-border">
                    <th className="text-left py-2 px-2">MATCH CODE</th>
                    <th className="text-left py-2 px-2">SHOOTER A</th>
                    <th className="text-left py-2 px-2">KILLS — SHOOTER A</th>
                    <th className="text-left py-2 px-2">SHOOTER B</th>
                    <th className="text-left py-2 px-2">KILLS — SHOOTER B</th>
                    <th className="text-left py-2 px-2">RESULT</th>
                  </tr>
                </thead>
                <tbody>
                  {list.map((m) => (
                    <MatchRow key={m.id} match={m} participants={participants} onChanged={loadAll} confirm={confirm} round={round} />
                  ))}
                </tbody>
              </table>
            </div>
          </Card>
        );
      })}
    </div>
  );
}

function MatchRow({ match, participants, onChanged, confirm, round }:
  { match: Match; participants: Participant[]; onChanged: () => void; confirm: any; round: string }) {
  const [a, setA] = useState<string | null>(match.participant_a_id);
  const [b, setB] = useState<string | null>(match.participant_b_id);
  const [kA, setKA] = useState<string>(match.kills_a?.toString() ?? "");
  const [kB, setKB] = useState<string>(match.kills_b?.toString() ?? "");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setA(match.participant_a_id);
    setB(match.participant_b_id);
    setKA(match.kills_a?.toString() ?? "");
    setKB(match.kills_b?.toString() ?? "");
  }, [match.id, match.participant_a_id, match.participant_b_id, match.kills_a, match.kills_b]);

  const pA = participants.find((p) => p.id === match.participant_a_id);
  const pB = participants.find((p) => p.id === match.participant_b_id);
  const settled = match.status !== "pending";

  // Only opening + first-round assignments are editable here; downstream slots auto-fill
  const isFirstRound = (round === "opening") || (round === "r16" && !participants.some((p) => false)); // placeholder

  async function saveAssignments() {
    setBusy(true);
    const { error } = await supabase.from("tournament_matches").update({
      participant_a_id: a, participant_b_id: b,
    }).eq("id", match.id);
    setBusy(false);
    if (error) toast.error(error.message); else { toast.success("Match updated"); onChanged(); }
  }

  async function markQualified(winnerId: string) {
    if (!a || !b) { toast.error("Assign both shooters first"); return; }
    const kAn = Number(kA), kBn = Number(kB);
    if (!Number.isFinite(kAn) || !Number.isFinite(kBn) || kAn < 0 || kBn < 0) {
      toast.error("Enter valid kill counts for both shooters first");
      return;
    }
    const winner = participants.find((p) => p.id === winnerId);
    const loser = participants.find((p) => p.id === (winnerId === a ? b : a));
    const ok = await confirm({
      title: `Mark ${winner?.display_name} as Qualified?`,
      description: `${winner?.display_name} (${winnerId === a ? kAn : kBn} kills) advances to the next round. ${loser?.display_name} (${winnerId === a ? kBn : kAn} kills) is eliminated. This updates user bet tickets in real time.`,
      confirmText: "Confirm Qualified",
    });
    if (!ok) return;
    setBusy(true);
    const { error } = await (supabase as any).rpc("tournament_set_result", {
      _match_id: match.id, _winner_id: winnerId, _kills_a: kAn, _kills_b: kBn,
    });
    setBusy(false);
    if (error) toast.error("Failed: " + error.message);
    else { toast.success(`${winner?.display_name} qualified`); onChanged(); }
  }

  async function markDisqualified(loserId: string) {
    if (!a || !b) { toast.error("Assign both shooters first"); return; }
    const kAn = Number(kA || "0"), kBn = Number(kB || "0");
    const dq = participants.find((p) => p.id === loserId);
    const winnerId = loserId === a ? b! : a!;
    const winner = participants.find((p) => p.id === winnerId);
    const ok = await confirm({
      title: `Disqualify ${dq?.display_name}?`,
      description: `${dq?.display_name} will be removed from the tournament. ${winner?.display_name} advances automatically.`,
      confirmText: "Confirm Disqualify",
    });
    if (!ok) return;
    setBusy(true);
    const { error } = await (supabase as any).rpc("tournament_disqualify", {
      _match_id: match.id, _disqualified_participant_id: loserId, _kills_a: kAn, _kills_b: kBn,
    });
    setBusy(false);
    if (error) toast.error("Failed: " + error.message);
    else { toast.success(`${dq?.display_name} disqualified`); onChanged(); }
  }

  const availablePool = participants.filter((p) => !p.is_eliminated || p.id === a || p.id === b);

  return (
    <tr className="border-b border-border/40">
      <td className="py-2 px-2 font-mono font-bold text-primary">{match.code}</td>
      <td className="py-2 px-2 min-w-[180px]">
        {match.round === "opening" ? (
          <Select value={a ?? "none"} onValueChange={(v) => setA(v === "none" ? null : v)} disabled={settled}>
            <SelectTrigger className="h-8 text-xs"><SelectValue placeholder="Pick shooter A" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="none">— None —</SelectItem>
              {availablePool.map((p) => <SelectItem key={p.id} value={p.id}>{p.display_name}</SelectItem>)}
            </SelectContent>
          </Select>
        ) : (
          <div className="text-xs font-bold">{pA?.display_name ?? <span className="text-muted-foreground italic">(awaiting winner)</span>}</div>
        )}
      </td>
      <td className="py-2 px-2 w-[110px]">
        <Input type="number" min={0} className="h-8 text-xs" placeholder="Kills A" value={kA} onChange={(e) => setKA(e.target.value)} disabled={settled} />
      </td>
      <td className="py-2 px-2 min-w-[180px]">
        {match.round === "opening" ? (
          <Select value={b ?? "none"} onValueChange={(v) => setB(v === "none" ? null : v)} disabled={settled}>
            <SelectTrigger className="h-8 text-xs"><SelectValue placeholder="Pick shooter B" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="none">— None —</SelectItem>
              {availablePool.map((p) => <SelectItem key={p.id} value={p.id}>{p.display_name}</SelectItem>)}
            </SelectContent>
          </Select>
        ) : (
          <div className="text-xs font-bold">{pB?.display_name ?? <span className="text-muted-foreground italic">(awaiting winner)</span>}</div>
        )}
      </td>
      <td className="py-2 px-2 w-[110px]">
        <Input type="number" min={0} className="h-8 text-xs" placeholder="Kills B" value={kB} onChange={(e) => setKB(e.target.value)} disabled={settled} />
      </td>
      <td className="py-2 px-2 min-w-[260px]">
        {settled ? (
          <div className="text-xs">
            <Badge variant="outline" className="border-emerald-400/40 text-emerald-400 mr-1">
              Winner: {participants.find((p) => p.id === match.winner_id)?.display_name}
            </Badge>
            <Badge variant="outline" className="border-red-400/40 text-red-400">
              Lost: {participants.find((p) => p.id === match.loser_id)?.display_name}
            </Badge>
          </div>
        ) : (
          <div className="flex flex-wrap gap-1">
            {match.round === "opening" && (a !== match.participant_a_id || b !== match.participant_b_id) && (
              <Button size="sm" variant="outline" disabled={busy} onClick={saveAssignments}>Save</Button>
            )}
            {a && b && (
              <>
                <Button size="sm" className="btn-luxury text-[10px] h-7" disabled={busy} onClick={() => markQualified(a!)}>
                  <Check className="h-3 w-3 mr-1" />A Qualified
                </Button>
                <Button size="sm" className="btn-luxury text-[10px] h-7" disabled={busy} onClick={() => markQualified(b!)}>
                  <Check className="h-3 w-3 mr-1" />B Qualified
                </Button>
                <Button size="sm" variant="destructive" className="text-[10px] h-7" disabled={busy} onClick={() => markDisqualified(a!)}>
                  <X className="h-3 w-3 mr-1" />DQ A
                </Button>
                <Button size="sm" variant="destructive" className="text-[10px] h-7" disabled={busy} onClick={() => markDisqualified(b!)}>
                  <X className="h-3 w-3 mr-1" />DQ B
                </Button>
              </>
            )}
          </div>
        )}
      </td>
    </tr>
  );
}

function ShooterSearchPicker({ shooters, onPick }: { shooters: any[]; onPick: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="outline" className="w-full justify-start text-xs h-9" role="combobox">
          <Search className="h-3.5 w-3.5 mr-2 opacity-60" />
          + Add shooter to bracket {shooters.length > 0 && <span className="ml-auto opacity-60">{shooters.length} available</span>}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-[320px] p-0" align="start">
        <Command>
          <CommandInput placeholder="Search by name or gang…" />
          <CommandList>
            <CommandEmpty>No shooters found.</CommandEmpty>
            <CommandGroup>
              {shooters.map((s) => (
                <CommandItem
                  key={s.id}
                  value={`${s.name} ${s.teams?.name ?? ""}`}
                  onSelect={() => { onPick(s.id); setOpen(false); }}
                >
                  <span className="font-bold">{s.name}</span>
                  {s.teams?.name && <span className="ml-2 text-muted-foreground text-xs">· {s.teams.name}</span>}
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
