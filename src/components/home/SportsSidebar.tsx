import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { supabase } from "@/integrations/supabase/client";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Flame, Dice5, Trophy, Crown, Skull, Crosshair, Swords, Gift, Target, Star, Search, ChevronRight, Circle } from "lucide-react";

type Row = { id: string; name: string; icon: string | null; link: string | null; is_pinned: boolean };

const ICON_MAP: Record<string, any> = {
  flame: Flame, dice: Dice5, trophy: Trophy, crown: Crown, skull: Skull,
  crosshair: Crosshair, swords: Swords, gift: Gift, target: Target, star: Star,
};

export function SportsSidebar() {
  const [items, setItems] = useState<Row[]>([]);
  const [q, setQ] = useState("");

  useEffect(() => {
    const load = () => supabase
      .from("sidebar_categories").select("*").eq("is_active", true)
      .order("sort_order").order("name")
      .then(({ data }) => setItems((data ?? []) as Row[]));
    load();
    const ch = supabase.channel("sidebar-cats")
      .on("postgres_changes", { event: "*", schema: "public", table: "sidebar_categories" }, load)
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, []);

  const filtered = q.trim() ? items.filter((i) => i.name.toLowerCase().includes(q.toLowerCase())) : items;
  const pinned = filtered.filter((i) => i.is_pinned);
  const others = filtered.filter((i) => !i.is_pinned);

  return (
    <Card className="glass p-3 sticky top-20">
      <div className="relative mb-3">
        <Search className="absolute left-2 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-muted-foreground" />
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search categories" className="h-8 pl-7 text-xs" />
      </div>
      {pinned.length > 0 && (
        <div className="space-y-0.5 mb-2">
          {pinned.map((i) => <SideRow key={i.id} row={i} highlight />)}
        </div>
      )}
      {others.length > 0 && (
        <>
          <div className="text-[9px] uppercase tracking-[0.3em] text-muted-foreground font-bold px-1 py-1.5 border-t border-border">Categories</div>
          <div className="space-y-0.5 max-h-[60vh] overflow-y-auto pr-1">
            {others.map((i) => <SideRow key={i.id} row={i} />)}
          </div>
        </>
      )}
      {filtered.length === 0 && <div className="text-xs text-muted-foreground p-2">No categories.</div>}
    </Card>
  );
}

function SideRow({ row, highlight }: { row: Row; highlight?: boolean }) {
  const Icon = (row.icon && ICON_MAP[row.icon]) || Circle;
  const cls = `group flex items-center gap-2 px-2 py-1.5 rounded text-xs transition ${highlight ? "text-primary hover:bg-primary/10" : "text-muted-foreground hover:text-foreground hover:bg-primary/5"}`;
  const inner = (
    <>
      <Icon className="h-3.5 w-3.5 shrink-0" />
      <span className="flex-1 truncate">{row.name}</span>
      <ChevronRight className="h-3 w-3 opacity-0 group-hover:opacity-60 transition" />
    </>
  );
  if (!row.link) return <div className={cls}>{inner}</div>;
  if (row.link.startsWith("http")) return <a className={cls} href={row.link} target="_blank" rel="noreferrer">{inner}</a>;
  return <Link className={cls} to={row.link as any}>{inner}</Link>;
}
