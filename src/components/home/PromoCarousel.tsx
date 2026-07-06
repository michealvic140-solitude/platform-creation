import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Carousel, CarouselContent, CarouselItem, CarouselNext, CarouselPrevious } from "@/components/ui/carousel";
import Autoplay from "embla-carousel-autoplay";
import { Card } from "@/components/ui/card";
import { Crosshair } from "lucide-react";

type Slide = { id: string; title: string; subtitle: string | null; image_url: string; cta_label: string | null; cta_link: string | null };

export function PromoCarousel() {
  const [items, setItems] = useState<Slide[]>([]);

  useEffect(() => {
    const load = () => supabase
      .from("promo_slides").select("*").eq("is_active", true)
      .order("sort_order").order("created_at", { ascending: false })
      .then(({ data }) => setItems((data ?? []) as Slide[]));
    load();
    const ch = supabase.channel("promo-slides")
      .on("postgres_changes", { event: "*", schema: "public", table: "promo_slides" }, load)
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, []);

  if (items.length === 0) return null;

  return (
    <section className="container mt-4">
      <Carousel opts={{ loop: items.length > 1, align: "start" }} plugins={items.length > 1 ? [Autoplay({ delay: 5500, stopOnInteraction: false })] : []}>
        <CarouselContent>
          {items.map((s) => {
            const inner = (
              <Card className="relative overflow-hidden border-primary/30 h-40 md:h-56">
                <img src={s.image_url} alt={s.title} className="absolute inset-0 h-full w-full object-cover" />
                <div className="absolute inset-0 bg-gradient-to-r from-background/85 via-background/40 to-transparent" />
                <div className="relative h-full p-4 md:p-6 flex flex-col justify-center max-w-[70%]">
                  <div className="flex items-center gap-1 text-[10px] uppercase tracking-[0.3em] text-primary font-bold mb-1">
                    <Crosshair className="h-3 w-3" /> Featured
                  </div>
                  <div className="text-xl md:text-3xl font-black gradient-gold-text leading-tight">{s.title}</div>
                  {s.subtitle && <div className="text-xs md:text-sm text-muted-foreground mt-1 line-clamp-2">{s.subtitle}</div>}
                  {s.cta_label && (
                    <div className="mt-3">
                      <span className="inline-flex items-center gap-1 px-3 py-1.5 rounded-md bg-gradient-gold text-primary-foreground text-xs font-black shadow-gold">
                        {s.cta_label}
                      </span>
                    </div>
                  )}
                </div>
              </Card>
            );
            return (
              <CarouselItem key={s.id} className="md:basis-2/3 lg:basis-1/2">
                {s.cta_link ? <a href={s.cta_link} target={s.cta_link.startsWith("http") ? "_blank" : undefined} rel="noreferrer">{inner}</a> : inner}
              </CarouselItem>
            );
          })}
        </CarouselContent>
        {items.length > 1 && <><CarouselPrevious /><CarouselNext /></>}
      </Carousel>
    </section>
  );
}
