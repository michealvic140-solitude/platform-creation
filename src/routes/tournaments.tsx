import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Layout } from "@/components/Layout";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Trophy, Crosshair, Calendar } from "lucide-react";

export const Route = createFileRoute("/tournaments")({
  head: () => ({
    meta: [
      { title: "Knockout Brackets — LSL" },
      { name: "description", content: "Browse all Lomita Shooters League knockout tournaments and follow the bracket live." },
      { property: "og:title", content: "LSL Knockout Brackets" },
      { property: "og:description", content: "One league. No mercy. Follow every bracket live." },
    ],
  }),
  component: TournamentsPage,
});

type Tournament = {
  id: string; name: string; tagline: string | null; banner_url: string | null;
  size: number; status: string; starts_at: string | null; champion_participant_id: string | null;
};

function TournamentsPage() {
  const [items, setItems] = useState<Tournament[]>([]);
  const [loading, setLoading] = useState(true);

  async function load() {
    const { data } = await supabase
      .from("tournaments")
      .select("*")
      .order("created_at", { ascending: false });
    setItems((data ?? []) as Tournament[]);
    setLoading(false);
  }

  useEffect(() => {
    load();
    const ch = supabase
      .channel("tournaments-list")
      .on("postgres_changes", { event: "*", schema: "public", table: "tournaments" }, load)
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, []);

  return (
    <Layout>
      <div className="container py-8 max-w-5xl">
        <div className="flex items-center gap-2 mb-1">
          <Crosshair className="h-6 w-6 text-primary" />
          <h1 className="text-3xl font-black gradient-gold-text tracking-tight">KNOCKOUT BRACKETS</h1>
        </div>
        <p className="text-muted-foreground text-sm mb-6">Pick a tournament to follow the live bracket — every round, matchup and the road to the champion.</p>

        {loading ? (
          <div className="text-center text-muted-foreground py-16">Loading…</div>
        ) : items.length === 0 ? (
          <Card className="glass p-10 text-center">
            <Trophy className="h-12 w-12 text-amber-400/60 mx-auto mb-3" />
            <div className="font-bold">No tournaments yet</div>
            <p className="text-sm text-muted-foreground mt-1">The next Knockout Bracket will appear here once an admin publishes it.</p>
          </Card>
        ) : (
          <div className="grid sm:grid-cols-2 gap-3">
            {items.map((t) => (
              <Link key={t.id} to="/tournament/$id" params={{ id: t.id }} className="block group">
                <Card className="glass overflow-hidden border-primary/30 hover:border-primary/60 transition">
                  <div
                    className="h-32 w-full relative"
                    style={{
                      backgroundImage: t.banner_url
                        ? `linear-gradient(180deg, rgba(0,8,0,0.3), rgba(0,8,0,0.85)), url(${t.banner_url})`
                        : "linear-gradient(180deg, rgba(0,40,0,0.6), rgba(0,8,0,0.95))",
                      backgroundSize: "cover", backgroundPosition: "center",
                    }}
                  >
                    <Badge variant="outline" className="absolute top-2 right-2 border-primary/40 text-primary capitalize">{t.status}</Badge>
                    {t.champion_participant_id && (
                      <Badge className="absolute top-2 left-2 bg-amber-500/90 text-black"><Trophy className="h-3 w-3 mr-1" />Champion crowned</Badge>
                    )}
                  </div>
                  <div className="p-3">
                    <div className="font-black tracking-wide truncate">{t.name}</div>
                    {t.tagline && <div className="text-xs text-muted-foreground italic truncate">{t.tagline}</div>}
                    <div className="mt-2 flex items-center gap-3 text-[11px] text-muted-foreground">
                      <span className="inline-flex items-center gap-1"><Crosshair className="h-3 w-3 text-primary" />{t.size} players</span>
                      {t.starts_at && <span className="inline-flex items-center gap-1"><Calendar className="h-3 w-3 text-primary" />{new Date(t.starts_at).toLocaleDateString("en-GB")}</span>}
                    </div>
                  </div>
                </Card>
              </Link>
            ))}
          </div>
        )}
      </div>
    </Layout>
  );
}
