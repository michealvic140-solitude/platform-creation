import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Ticket as TicketIcon, MessageCircle, Mail, Phone, Trash2, Coins } from "lucide-react";
import { useBetSlip } from "@/contexts/BetSlipContext";
import { useNavigate } from "@tanstack/react-router";
import { toast } from "sonner";

export function RightRail() {
  const { selections, remove, clear, setOpen } = useBetSlip();
  const [code, setCode] = useState("");
  const [s, setS] = useState<any>(null);
  const nav = useNavigate();

  useEffect(() => {
    supabase.from("app_settings").select("contact_email,contact_phone,contact_whatsapp").eq("id", 1).maybeSingle().then(({ data }) => setS(data));
  }, []);

  const totalOdds = selections.reduce((a, s) => a * s.odds, 1);

  return (
    <aside className="space-y-3 sticky top-20 self-start">
      {/* Betslip mini */}
      <Card className="glass border-primary/30 overflow-hidden">
        <div className="px-3 py-2 border-b border-primary/30 bg-primary/5 flex items-center justify-between">
          <div className="flex items-center gap-1.5 text-primary font-black text-sm"><TicketIcon className="h-4 w-4" /> Betslip</div>
          {selections.length > 0 && <button onClick={clear} className="text-[10px] text-muted-foreground hover:text-destructive"><Trash2 className="h-3 w-3" /></button>}
        </div>
        {selections.length === 0 ? (
          <div className="p-4 text-xs text-muted-foreground text-center">
            Your betslip is empty.<br />
            <span className="text-[11px]">Tap odds to add selections and place a bet.</span>
          </div>
        ) : (
          <div className="p-2 space-y-1.5">
            {selections.slice(0, 4).map((sel) => (
              <div key={sel.odd_id} className="flex items-center gap-2 text-[11px] p-1.5 rounded bg-card/60">
                <div className="min-w-0 flex-1">
                  <div className="font-bold truncate">{sel.match_name}</div>
                  <div className="text-muted-foreground truncate">{sel.selection_label}</div>
                </div>
                <div className="font-mono font-black text-primary tabular-nums">{sel.odds.toFixed(2)}</div>
                <button onClick={() => remove(sel.odd_id)} className="text-muted-foreground hover:text-destructive"><Trash2 className="h-3 w-3" /></button>
              </div>
            ))}
            {selections.length > 4 && <div className="text-[10px] text-muted-foreground text-center">+{selections.length - 4} more</div>}
            <div className="pt-2 border-t border-border/40 flex items-center justify-between text-xs">
              <span className="text-muted-foreground">Total odds</span>
              <span className="font-black text-primary tabular-nums">{totalOdds.toFixed(2)}</span>
            </div>
            <Button size="sm" className="w-full btn-luxury mt-1" onClick={() => setOpen(true)}>
              <Coins className="h-3.5 w-3.5 mr-1" /> Place Bet
            </Button>
          </div>
        )}
      </Card>

      {/* Booking / coupon code */}
      <Card className="glass border-accent/30 p-3">
        <div className="text-xs font-black tracking-wider text-accent mb-1">BOOK</div>
        <div className="text-[10px] text-muted-foreground mb-2">Insert a booking code to load a coupon.</div>
        <div className="flex gap-1">
          <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="Code" className="h-8 text-xs" />
          <Button size="sm" className="h-8 px-3" onClick={() => {
            if (!code.trim()) return;
            nav({ to: "/ticket/$id", params: { id: code.trim() } });
          }}>Book</Button>
        </div>
        <div className="mt-3 text-xs font-black tracking-wider text-accent mb-1">CHECK BET</div>
        <div className="text-[10px] text-muted-foreground mb-2">Verify a bet ID.</div>
        <div className="flex gap-1">
          <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="Bet ID" className="h-8 text-xs" />
          <Button size="sm" variant="outline" className="h-8 px-3" onClick={() => code.trim() && nav({ to: "/ticket/$id", params: { id: code.trim() } })}>Check</Button>
        </div>
      </Card>

      {/* Contact us */}
      {(s?.contact_email || s?.contact_phone || s?.contact_whatsapp) && (
        <Card className="glass border-emerald-500/30 overflow-hidden">
          <div className="px-3 py-2 border-b border-emerald-500/30 bg-emerald-500/10 flex items-center gap-1.5">
            <MessageCircle className="h-4 w-4 text-emerald-400" />
            <span className="text-sm font-black tracking-wider text-emerald-400">CONTACT US</span>
          </div>
          <div className="p-3 space-y-1.5 text-xs">
            {s.contact_email && (
              <a href={`mailto:${s.contact_email}`} className="flex items-center gap-2 text-muted-foreground hover:text-primary">
                <Mail className="h-3.5 w-3.5" /> <span className="truncate">{s.contact_email}</span>
              </a>
            )}
            {s.contact_phone && (
              <a href={`tel:${s.contact_phone}`} className="flex items-center gap-2 text-muted-foreground hover:text-primary">
                <Phone className="h-3.5 w-3.5" /> <span className="truncate">{s.contact_phone}</span>
              </a>
            )}
            {s.contact_whatsapp && (
              <a href={`https://wa.me/${s.contact_whatsapp.replace(/[^0-9]/g, "")}`} target="_blank" rel="noreferrer" className="flex items-center gap-2 text-emerald-400 hover:text-emerald-300 font-semibold">
                <MessageCircle className="h-3.5 w-3.5" /> WhatsApp
              </a>
            )}
          </div>
        </Card>
      )}
    </aside>
  );
}
