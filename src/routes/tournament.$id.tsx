import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Layout } from "@/components/Layout";
import { Badge } from "@/components/ui/badge";
import { Trophy, Crosshair, Calendar, ArrowLeft } from "lucide-react";
import lslLogo from "@/assets/lsl-logo.png";

export const Route = createFileRoute("/tournament/$id")({
  head: () => ({ meta: [{ title: "Knockout Bracket — LSL" }] }),
  component: TournamentPage,
});

type Tournament = { id: string; name: string; tagline: string | null; banner_url: string | null; size: number; status: string; starts_at: string | null; champion_participant_id: string | null };
type Participant = { id: string; display_name: string; gang_tag: string | null; is_eliminated: boolean; eliminated_at_round: string | null };
type Match = { id: string; round: string; slot_index: number; code: string; participant_a_id: string | null; participant_b_id: string | null; kills_a: number | null; kills_b: number | null; winner_id: string | null; loser_id: string | null; status: string };

function TournamentPage() {
  const { id } = Route.useParams();
  const [tournament, setTournament] = useState<Tournament | null>(null);
  const [participants, setParticipants] = useState<Participant[]>([]);
  const [matches, setMatches] = useState<Match[]>([]);

  async function load() {
    const [{ data: t }, { data: p }, { data: m }] = await Promise.all([
      supabase.from("tournaments").select("*").eq("id", id).maybeSingle(),
      supabase.from("tournament_participants").select("*").eq("tournament_id", id),
      supabase.from("tournament_matches").select("*").eq("tournament_id", id).order("round").order("slot_index"),
    ]);
    setTournament(t as Tournament | null);
    setParticipants((p ?? []) as Participant[]);
    setMatches((m ?? []) as Match[]);
  }

  useEffect(() => { load(); }, [id]);
  useEffect(() => {
    const ch = supabase.channel(`bracket-${id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "tournament_matches", filter: `tournament_id=eq.${id}` }, load)
      .on("postgres_changes", { event: "*", schema: "public", table: "tournament_participants", filter: `tournament_id=eq.${id}` }, load)
      .on("postgres_changes", { event: "*", schema: "public", table: "tournaments", filter: `id=eq.${id}` }, load)
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [id]);

  if (!tournament) return <Layout><div className="container py-10 text-center">Loading bracket…</div></Layout>;

  return (
    <Layout>
      <BracketView tournament={tournament} participants={participants} matches={matches} />
    </Layout>
  );
}

export function BracketView({ tournament, participants, matches }: { tournament: Tournament; participants: Participant[]; matches: Match[] }) {
  const byRound = useMemo(() => {
    const o: Record<string, Match[]> = { opening: [], r16: [], qf: [], sf: [], final: [] };
    for (const m of matches) o[m.round]?.push(m);
    return o;
  }, [matches]);

  const pMap = useMemo(() => {
    const m: Record<string, Participant> = {};
    for (const p of participants) m[p.id] = p;
    return m;
  }, [participants]);

  // Build "lost-to" lookup for eliminated participants
  const lostTo = useMemo(() => {
    const map: Record<string, { to: string; kills: string }> = {};
    for (const m of matches) {
      if (m.loser_id && m.winner_id) {
        const winner = participants.find((p) => p.id === m.winner_id);
        const loserKills = m.loser_id === m.participant_a_id ? m.kills_a : m.kills_b;
        const winnerKills = m.winner_id === m.participant_a_id ? m.kills_a : m.kills_b;
        map[m.loser_id] = { to: winner?.display_name ?? "Unknown", kills: `${loserKills ?? 0}-${winnerKills ?? 0}` };
      }
    }
    return map;
  }, [matches, participants]);

  const champion = tournament.champion_participant_id ? pMap[tournament.champion_participant_id] : null;
  const hasOpening = byRound.opening.length > 0;
  const dateStr = new Date(tournament.starts_at ?? tournament.banner_url ?? Date.now()).toLocaleDateString("en-GB");

  return (
    <div className="min-h-[calc(100vh-3.5rem)] w-full bg-[#0a0f0a] text-foreground">
      {/* Top bar with banner */}
      <div className="relative w-full border-b border-primary/30" style={{
        backgroundImage: tournament.banner_url
          ? `linear-gradient(180deg, rgba(0,8,0,0.6), rgba(0,8,0,0.9)), url(${tournament.banner_url})`
          : "linear-gradient(180deg, rgba(0,16,0,0.95), rgba(0,8,0,0.95))",
        backgroundSize: "cover", backgroundPosition: "center",
      }}>
        <div className="mx-auto max-w-[1400px] px-4 py-4 flex items-center gap-3 flex-wrap">
          <Link to="/" className="text-xs text-muted-foreground hover:text-primary inline-flex items-center gap-1"><ArrowLeft className="h-3 w-3" />Home</Link>
          <div className="flex items-center gap-2">
            <div className="h-12 w-12 rounded-xl bg-gradient-gold grid place-items-center shadow-gold">
              <img src={lslLogo} alt="LSL" className="h-10 w-10 object-contain" />
            </div>
            <div>
              <div className="text-[10px] tracking-widest text-muted-foreground">LOMITA SHOOTERS LEAGUE</div>
              <div className="text-2xl sm:text-3xl font-black gradient-gold-text tracking-tight">KNOCKOUT BRACKET</div>
            </div>
          </div>
          <Badge variant="outline" className="ml-auto border-primary/40 text-primary"><Calendar className="h-3 w-3 mr-1" />{dateStr}</Badge>
        </div>
        <div className="text-center pb-3 text-xs sm:text-sm italic tracking-wider text-muted-foreground">{tournament.tagline}</div>
      </div>

      {/* Bracket grid — fits the viewport, no horizontal scroll */}
      <div className="mx-auto max-w-[1400px] px-2 sm:px-4 py-4">
        <div className={`grid gap-2 ${hasOpening ? "grid-cols-5" : "grid-cols-4"}`}>
          {hasOpening && <RoundColumn title="OPENING ROUND" subtitle={`ROUND OF ${tournament.size}`} matches={byRound.opening} pMap={pMap} lostTo={lostTo} compact />}
          <RoundColumn title="ROUND OF 16" subtitle="16 PLAYERS" matches={byRound.r16} pMap={pMap} lostTo={lostTo} />
          <RoundColumn title="QUARTERFINALS" subtitle="8 PLAYERS" matches={byRound.qf} pMap={pMap} lostTo={lostTo} />
          <RoundColumn title="SEMIFINALS" subtitle="4 PLAYERS" matches={byRound.sf} pMap={pMap} lostTo={lostTo} />
          <RoundColumn title="GRAND FINAL" subtitle="2 PLAYERS" matches={byRound.final} pMap={pMap} lostTo={lostTo} trophy={champion} />
        </div>

        {/* Format strip */}
        <div className="mt-6 rounded-2xl border border-primary/30 bg-black/40 p-4">
          <div className="text-center text-xs tracking-[0.3em] text-primary font-bold mb-3">TOURNAMENT FORMAT</div>
          <div className="flex flex-wrap items-center justify-center gap-3 text-[10px] sm:text-xs">
            {hasOpening && <FormatNode title="OPENING ROUND" sub={`ROUND OF ${tournament.size}`} count={`${tournament.size} PLAYERS`} arrow />}
            <FormatNode title="ROUND OF 16" sub="" count="16 PLAYERS" arrow />
            <FormatNode title="QUARTERFINALS" sub="" count="8 PLAYERS" arrow />
            <FormatNode title="SEMIFINALS" sub="" count="4 PLAYERS" arrow />
            <FormatNode title="GRAND FINAL" sub="" count="2 PLAYERS" arrow />
            <div className="inline-flex items-center gap-1 text-primary font-black tracking-widest"><Trophy className="h-4 w-4" />CHAMPION</div>
          </div>
          <div className="mt-3 flex flex-wrap items-center justify-center gap-6 text-[10px] sm:text-xs text-muted-foreground tracking-widest">
            <span className="inline-flex items-center gap-1"><Crosshair className="h-3 w-3 text-primary" /> ONE LEAGUE. NO MERCY.</span>
            <span className="inline-flex items-center gap-1"><Trophy className="h-3 w-3 text-primary" /> RESPECT THE GAME.</span>
            <span className="inline-flex items-center gap-1"><Trophy className="h-3 w-3 text-primary" /> ONLY ONE KING.</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function FormatNode({ title, sub, count, arrow }: { title: string; sub: string; count: string; arrow?: boolean }) {
  return (
    <div className="inline-flex items-center gap-2">
      <div className="text-center">
        <div className="font-bold text-primary tracking-widest">{title}</div>
        {sub && <div className="text-muted-foreground">{sub}</div>}
        <div className="text-muted-foreground">{count}</div>
      </div>
      {arrow && <span className="text-primary">→</span>}
    </div>
  );
}

function RoundColumn({ title, subtitle, matches, pMap, lostTo, compact, trophy }:
  { title: string; subtitle: string; matches: Match[]; pMap: Record<string, Participant>; lostTo: Record<string, { to: string; kills: string }>; compact?: boolean; trophy?: Participant | null }) {
  return (
    <div className="flex flex-col">
      <div className="text-center mb-2">
        <div className="text-[10px] sm:text-xs font-black tracking-widest text-primary">{title}</div>
        <div className="text-[9px] sm:text-[10px] text-muted-foreground tracking-widest">{subtitle}</div>
      </div>
      <div className={`flex-1 flex flex-col ${compact ? "gap-1" : "gap-2"} justify-around`}>
        {matches.map((m) => (
          <MatchCell key={m.id} m={m} pMap={pMap} lostTo={lostTo} compact={compact} />
        ))}
        {trophy !== undefined && (
          <div className="mt-3 flex flex-col items-center">
            <div className="relative">
              <Trophy className="h-16 w-16 text-amber-400" strokeWidth={1.2} fill="currentColor" />
              {trophy && <div className="absolute -bottom-1 left-1/2 -translate-x-1/2 text-amber-400 text-[10px] font-black whitespace-nowrap">★★★</div>}
            </div>
            <div className="mt-2 text-amber-400 font-black tracking-widest text-sm">CHAMPION</div>
            {trophy && <div className="mt-1 text-xs font-bold text-primary text-center">{trophy.display_name}</div>}
          </div>
        )}
      </div>
    </div>
  );
}

function MatchCell({ m, pMap, lostTo, compact }: { m: Match; pMap: Record<string, Participant>; lostTo: Record<string, { to: string; kills: string }>; compact?: boolean }) {
  const a = m.participant_a_id ? pMap[m.participant_a_id] : null;
  const b = m.participant_b_id ? pMap[m.participant_b_id] : null;
  const settled = m.status === "qualified";
  const winnerIsA = m.winner_id === m.participant_a_id;
  const winnerIsB = m.winner_id === m.participant_b_id;

  return (
    <div className={`rounded-lg border border-primary/30 bg-black/60 ${compact ? "p-1.5" : "p-2"} shadow-[0_0_0_1px_rgba(212,175,55,0.05)]`}>
      <div className={`text-[8px] sm:text-[9px] tracking-widest text-primary font-bold ${compact ? "mb-0.5" : "mb-1"} flex items-center justify-between`}>
        <span>{m.code}</span>
        {settled && <span className="text-emerald-400 normal-case">✓</span>}
      </div>
      <PlayerRow p={a} kills={m.kills_a} isWinner={winnerIsA} isLoser={!!m.loser_id && m.loser_id === m.participant_a_id} lostTo={a ? lostTo[a.id] : undefined} compact={compact} />
      <div className={`text-center text-[8px] text-muted-foreground ${compact ? "py-0" : "py-0.5"}`}>VS</div>
      <PlayerRow p={b} kills={m.kills_b} isWinner={winnerIsB} isLoser={!!m.loser_id && m.loser_id === m.participant_b_id} lostTo={b ? lostTo[b.id] : undefined} compact={compact} />
    </div>
  );
}

function PlayerRow({ p, kills, isWinner, isLoser, lostTo, compact }:
  { p: Participant | null; kills: number | null; isWinner: boolean; isLoser: boolean; lostTo?: { to: string; kills: string }; compact?: boolean }) {
  if (!p) return <div className={`text-muted-foreground italic ${compact ? "text-[9px]" : "text-[10px] sm:text-xs"} text-center`}>— TBD —</div>;
  return (
    <div className={`flex items-center justify-between gap-1 ${compact ? "text-[9px]" : "text-[10px] sm:text-xs"} ${isWinner ? "text-emerald-400 font-black" : isLoser ? "text-red-400/80 line-through" : "text-foreground"}`}>
      <div className="truncate">
        <div className="truncate font-bold leading-tight">{p.display_name}</div>
        {p.gang_tag && !compact && <div className="text-[8px] sm:text-[9px] text-muted-foreground truncate normal-case no-underline">{p.gang_tag}</div>}
        {isLoser && lostTo && !compact && <div className="text-[8px] text-red-400/70 truncate no-underline">Lost to {lostTo.to} · {lostTo.kills}</div>}
      </div>
      {kills !== null && <span className="font-mono tabular-nums shrink-0">{kills}</span>}
    </div>
  );
}
