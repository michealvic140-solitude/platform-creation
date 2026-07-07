import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Carousel, CarouselContent, CarouselItem, CarouselNext, CarouselPrevious } from "@/components/ui/carousel";
import Autoplay from "embla-carousel-autoplay";
import { ChevronRight, Newspaper, Ticket as TicketIcon, Trophy } from "lucide-react";
import { Countdown } from "@/components/Countdown";

const db: any = supabase;

function useRows<T = any>(table: string, deps: string[] = []) {
  const [rows, setRows] = useState<T[]>([]);
  useEffect(() => {
    const load = async () => {
      const { data } = await db.from(table).select("*").eq("is_active", true).order("sort_order", { ascending: true });
      setRows((data ?? []) as T[]);
    };
    load();
    const ch = db.channel(`home-${table}`)
      .on("postgres_changes", { event: "*", schema: "public", table }, load)
      .subscribe();
    return () => { db.removeChannel(ch); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return rows;
}

/* ---------- Popular quick-links rail ---------- */
export function PopularRail() {
  const links = useRows<any>("home_popular_links");
  if (links.length === 0) return null;
  return (
    <Card className="glass p-2 lg:p-3">
      <div className="text-[11px] font-bold tracking-widest text-accent px-2 pt-1 pb-2 uppercase">Popular</div>
      <ul className="space-y-1">
        {links.map((l) => (
          <li key={l.id}>
            <a
              href={l.target_url}
              className="flex items-center justify-between gap-2 px-3 py-2 rounded-md text-sm hover:bg-primary/10 hover:text-primary transition"
            >
              <span className="truncate">{l.label}</span>
              <ChevronRight className="h-3.5 w-3.5 shrink-0 opacity-60" />
            </a>
          </li>
        ))}
      </ul>
    </Card>
  );
}

/* ---------- Hero banner carousel ---------- */
export function HeroBannerSlider() {
  const slides = useRows<any>("home_hero_slides");
  if (slides.length === 0) return null;
  return (
    <Carousel opts={{ loop: true }} plugins={[Autoplay({ delay: 5500 })]} className="w-full">
      <CarouselContent>
        {slides.map((s) => {
          const body = (
            <div className="relative overflow-hidden rounded-xl border border-primary/30 shadow-luxury aspect-[16/7] md:aspect-[21/8]">
              <img src={s.image_url} alt={s.title ?? ""} className="absolute inset-0 h-full w-full object-cover" />
              <div className="absolute inset-0 bg-gradient-to-r from-background/70 via-background/10 to-transparent" />
              {(s.title || s.subtitle || s.cta_label) && (
                <div className="relative h-full flex flex-col justify-center gap-2 p-5 md:p-8 max-w-[65%]">
                  {s.title && <h3 className="text-xl md:text-4xl font-black gradient-gold-text leading-tight">{s.title}</h3>}
                  {s.subtitle && <p className="text-xs md:text-sm text-foreground/80 line-clamp-2">{s.subtitle}</p>}
                  {s.cta_label && (
                    <div className="mt-2">
                      <Button size="sm" className="btn-luxury">{s.cta_label}<ChevronRight className="h-4 w-4 ml-1" /></Button>
                    </div>
                  )}
                </div>
              )}
            </div>
          );
          return (
            <CarouselItem key={s.id}>
              {s.cta_url ? <a href={s.cta_url}>{body}</a> : body}
            </CarouselItem>
          );
        })}
      </CarouselContent>
      <CarouselPrevious />
      <CarouselNext />
    </Carousel>
  );
}

/* ---------- Featured / Highlight / Gifts tabbed row ---------- */
type Tab = "featured" | "highlight" | "gifts";
const TABS: { key: Tab; label: string }[] = [
  { key: "featured", label: "Featured Games" },
  { key: "highlight", label: "Highlight" },
  { key: "gifts", label: "Gifts" },
];

export function FeaturedTabsRow() {
  const [tab, setTab] = useState<Tab>("featured");
  const tiles = useRows<any>("home_featured_tiles");
  const filtered = tiles.filter((t) => t.tab === tab);
  if (tiles.length === 0) return null;
  return (
    <Card className="glass p-3 md:p-4">
      <div className="flex items-center gap-4 md:gap-8 border-b border-border/60 mb-4 overflow-x-auto no-scrollbar">
        {TABS.map((t) => {
          const active = tab === t.key;
          return (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`relative py-2 text-sm md:text-base font-bold whitespace-nowrap transition ${active ? "text-primary" : "text-muted-foreground hover:text-foreground"}`}
            >
              {t.label}
              {active && <span className="absolute -bottom-px left-0 right-0 h-0.5 bg-primary rounded-full" />}
            </button>
          );
        })}
      </div>
      {filtered.length === 0 ? (
        <p className="text-sm text-muted-foreground py-6 text-center">No {tab} tiles yet.</p>
      ) : (
        <Carousel opts={{ align: "start", dragFree: true }}>
          <CarouselContent>
            {filtered.map((t) => {
              const inner = (
                <Card className="overflow-hidden border-primary/20 hover:border-primary/50 transition">
                  <div className="aspect-[4/3] overflow-hidden">
                    <img src={t.image_url} alt={t.title ?? ""} className="h-full w-full object-cover" />
                  </div>
                  {(t.title || t.cta_label) && (
                    <div className="p-2 text-center">
                      <div className="text-xs md:text-sm font-bold truncate text-primary">{t.cta_label ?? t.title}</div>
                    </div>
                  )}
                </Card>
              );
              return (
                <CarouselItem key={t.id} className="basis-[45%] sm:basis-1/3 md:basis-1/4 lg:basis-1/5">
                  {t.cta_url ? <a href={t.cta_url}>{inner}</a> : inner}
                </CarouselItem>
              );
            })}
          </CarouselContent>
          <CarouselPrevious />
          <CarouselNext />
        </Carousel>
      )}
    </Card>
  );
}

/* ---------- Lottery draws ---------- */
export function LotteryDrawsPanel() {
  const draws = useRows<any>("home_lottery_draws");
  if (draws.length === 0) return null;
  return (
    <Card className="glass p-3 md:p-4">
      <div className="flex items-center gap-2 mb-3">
        <TicketIcon className="h-4 w-4 text-accent" />
        <div className="text-sm font-bold tracking-widest uppercase text-accent">Lottery</div>
      </div>
      <div className="grid sm:grid-cols-2 gap-3">
        {draws.map((d) => (
          <Card key={d.id} className="p-3 border-accent/25">
            <div className="flex items-center justify-between gap-2">
              <div className="font-bold">{d.name}</div>
              {d.ends_at && (
                <div className="text-[10px] font-mono text-primary"><Countdown target={d.ends_at} /></div>
              )}
            </div>
            {d.prize_label && (
              <div className="mt-1 text-xs">
                <span className="text-amber-300 font-black">🎁 WIN </span>
                <span className="text-primary font-black">{d.prize_label}</span>
              </div>
            )}
            {d.numbers && d.numbers.length > 0 && (
              <div className="mt-2 flex flex-wrap gap-1">
                {d.numbers.map((n: number, i: number) => (
                  <span key={i} className="h-6 min-w-6 px-1.5 grid place-items-center rounded-full text-[10px] font-bold border border-accent/40 text-accent">{n}</span>
                ))}
              </div>
            )}
            {d.cta_url && d.cta_label && (
              <div className="mt-3">
                <a href={d.cta_url}><Button size="sm" className="btn-luxury w-full">{d.cta_label}</Button></a>
              </div>
            )}
          </Card>
        ))}
      </div>
    </Card>
  );
}

/* ---------- News feed ---------- */
export function NewsPanel() {
  const posts = useRows<any>("home_news_posts");
  if (posts.length === 0) return null;
  return (
    <Card className="glass p-3 md:p-4">
      <div className="flex items-center gap-2 mb-3">
        <Newspaper className="h-4 w-4 text-primary" />
        <div className="text-sm font-bold tracking-widest uppercase text-primary">News</div>
      </div>
      <Carousel opts={{ loop: posts.length > 1 }} plugins={posts.length > 1 ? [Autoplay({ delay: 6000 })] : []}>
        <CarouselContent>
          {posts.map((n) => {
            const body = (
              <Card className="overflow-hidden">
                {n.image_url && <img src={n.image_url} alt={n.title} className="w-full aspect-video object-cover" />}
                <div className="p-3">
                  <div className="font-bold text-sm line-clamp-2">{n.title}</div>
                  {n.body && <div className="text-xs text-muted-foreground line-clamp-2 mt-1">{n.body}</div>}
                </div>
              </Card>
            );
            return (
              <CarouselItem key={n.id}>
                {n.link_url ? <a href={n.link_url}>{body}</a> : body}
              </CarouselItem>
            );
          })}
        </CarouselContent>
      </Carousel>
    </Card>
  );
}

/* ---------- Lottery results ---------- */
export function LotteryResultsPanel() {
  const results = useRows<any>("home_lottery_results");
  if (results.length === 0) return null;
  return (
    <Card className="glass p-3 md:p-4">
      <div className="flex items-center gap-2 mb-3">
        <Trophy className="h-4 w-4 text-amber-300" />
        <div className="text-sm font-bold tracking-widest uppercase text-amber-300">Lottery Results</div>
      </div>
      <div className="space-y-3">
        {results.map((r) => (
          <div key={r.id} className="pb-3 border-b border-border/40 last:border-0 last:pb-0">
            <div className="flex justify-between items-baseline">
              <div className="font-bold text-sm">{r.draw_name}</div>
              {r.draw_no && <div className="text-[10px] text-muted-foreground">NO. {r.draw_no}</div>}
            </div>
            {r.numbers && r.numbers.length > 0 && (
              <div className="mt-1.5 flex flex-wrap gap-1">
                {r.numbers.map((n: number, i: number) => (
                  <span key={i} className="h-6 min-w-6 px-1.5 grid place-items-center rounded-full text-[10px] font-bold border border-amber-400/50 text-amber-300 bg-amber-500/5">{n}</span>
                ))}
              </div>
            )}
            {r.winnings_label && (
              <div className="mt-1 text-xs font-bold text-emerald-300">Win: {r.winnings_label}</div>
            )}
          </div>
        ))}
      </div>
    </Card>
  );
}
