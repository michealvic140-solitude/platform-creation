import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Switch } from "@/components/ui/switch";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { Plus, Trash2, ImagePlus, LayoutList, Save } from "lucide-react";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";

type Slide = { id: string; title: string; subtitle: string | null; image_url: string; cta_label: string | null; cta_link: string | null; sort_order: number; is_active: boolean };
type Cat = { id: string; name: string; icon: string | null; link: string | null; sort_order: number; is_active: boolean; is_pinned: boolean };

const ICON_KEYS = ["flame", "dice", "trophy", "crown", "skull", "crosshair", "swords", "gift", "target", "star"];

export function HomeCMSPanel() {
  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-black gradient-gold-text">Homepage CMS</h2>
        <p className="text-xs text-muted-foreground">Manage the top promo carousel slides and the left sports/leagues sidebar.</p>
      </div>
      <Tabs defaultValue="slides">
        <TabsList>
          <TabsTrigger value="slides"><ImagePlus className="h-4 w-4 mr-1" /> Promo Slides</TabsTrigger>
          <TabsTrigger value="cats"><LayoutList className="h-4 w-4 mr-1" /> Sidebar Categories</TabsTrigger>
        </TabsList>
        <TabsContent value="slides" className="mt-4"><SlidesEditor /></TabsContent>
        <TabsContent value="cats" className="mt-4"><CatsEditor /></TabsContent>
      </Tabs>
    </div>
  );
}

function SlidesEditor() {
  const [rows, setRows] = useState<Slide[]>([]);
  const load = () => supabase.from("promo_slides").select("*").order("sort_order").then(({ data }) => setRows((data ?? []) as Slide[]));
  useEffect(() => { load(); }, []);

  const add = async () => {
    const { error } = await supabase.from("promo_slides").insert({ title: "New slide", image_url: "https://placehold.co/1200x400/1a1a1a/gold?text=New+Slide", sort_order: (rows.at(-1)?.sort_order ?? 0) + 10 });
    if (error) { toast.error(error.message); return; }
    load();
  };

  return (
    <div className="space-y-3">
      <Button onClick={add} size="sm" className="btn-luxury"><Plus className="h-4 w-4 mr-1" /> Add Slide</Button>
      {rows.length === 0 && <p className="text-xs text-muted-foreground">No slides yet.</p>}
      {rows.map((r) => <SlideRow key={r.id} row={r} onChange={load} />)}
    </div>
  );
}

function SlideRow({ row, onChange }: { row: Slide; onChange: () => void }) {
  const [r, setR] = useState<Slide>(row);
  const [saving, setSaving] = useState(false);
  useEffect(() => setR(row), [row]);

  const save = async () => {
    setSaving(true);
    const { error } = await supabase.from("promo_slides").update({
      title: r.title, subtitle: r.subtitle, image_url: r.image_url,
      cta_label: r.cta_label, cta_link: r.cta_link,
      sort_order: r.sort_order, is_active: r.is_active,
    }).eq("id", r.id);
    setSaving(false);
    if (error) toast.error(error.message); else { toast.success("Slide saved"); onChange(); }
  };
  const del = async () => {
    if (!confirm(`Delete slide "${r.title}"?`)) return;
    const { error } = await supabase.from("promo_slides").delete().eq("id", r.id);
    if (error) toast.error(error.message); else onChange();
  };

  return (
    <Card className="p-3 space-y-2">
      <div className="grid md:grid-cols-[120px_1fr] gap-3">
        {r.image_url && <img src={r.image_url} alt="" className="h-24 w-full md:w-[120px] object-cover rounded border border-border" />}
        <div className="grid sm:grid-cols-2 gap-2">
          <div><Label className="text-[10px]">Title</Label><Input value={r.title} onChange={(e) => setR({ ...r, title: e.target.value })} /></div>
          <div><Label className="text-[10px]">Sort order</Label><Input type="number" value={r.sort_order} onChange={(e) => setR({ ...r, sort_order: Number(e.target.value) })} /></div>
          <div className="sm:col-span-2"><Label className="text-[10px]">Subtitle</Label><Textarea rows={2} value={r.subtitle ?? ""} onChange={(e) => setR({ ...r, subtitle: e.target.value })} /></div>
          <div className="sm:col-span-2"><Label className="text-[10px]">Image URL</Label><Input value={r.image_url} onChange={(e) => setR({ ...r, image_url: e.target.value })} /></div>
          <div><Label className="text-[10px]">CTA label</Label><Input value={r.cta_label ?? ""} onChange={(e) => setR({ ...r, cta_label: e.target.value })} /></div>
          <div><Label className="text-[10px]">CTA link</Label><Input value={r.cta_link ?? ""} onChange={(e) => setR({ ...r, cta_link: e.target.value })} /></div>
          <div className="flex items-center gap-2 pt-4"><Switch checked={r.is_active} onCheckedChange={(v) => setR({ ...r, is_active: v })} /><Label className="text-xs">Active</Label></div>
          <div className="flex items-center gap-2 pt-4 justify-end">
            <Button size="sm" variant="destructive" onClick={del}><Trash2 className="h-4 w-4" /></Button>
            <Button size="sm" className="btn-luxury" disabled={saving} onClick={save}><Save className="h-4 w-4 mr-1" /> Save</Button>
          </div>
        </div>
      </div>
    </Card>
  );
}

function CatsEditor() {
  const [rows, setRows] = useState<Cat[]>([]);
  const load = () => supabase.from("sidebar_categories").select("*").order("sort_order").then(({ data }) => setRows((data ?? []) as Cat[]));
  useEffect(() => { load(); }, []);

  const add = async () => {
    const { error } = await supabase.from("sidebar_categories").insert({ name: "New category", icon: "crosshair", link: "/matches", sort_order: (rows.at(-1)?.sort_order ?? 0) + 10 });
    if (error) { toast.error(error.message); return; }
    load();
  };

  return (
    <div className="space-y-3">
      <Button onClick={add} size="sm" className="btn-luxury"><Plus className="h-4 w-4 mr-1" /> Add Category</Button>
      {rows.length === 0 && <p className="text-xs text-muted-foreground">No sidebar entries.</p>}
      {rows.map((r) => <CatRow key={r.id} row={r} onChange={load} />)}
    </div>
  );
}

function CatRow({ row, onChange }: { row: Cat; onChange: () => void }) {
  const [r, setR] = useState<Cat>(row);
  const [saving, setSaving] = useState(false);
  useEffect(() => setR(row), [row]);

  const save = async () => {
    setSaving(true);
    const { error } = await supabase.from("sidebar_categories").update({
      name: r.name, icon: r.icon, link: r.link, sort_order: r.sort_order, is_active: r.is_active, is_pinned: r.is_pinned,
    }).eq("id", r.id);
    setSaving(false);
    if (error) toast.error(error.message); else { toast.success("Saved"); onChange(); }
  };
  const del = async () => {
    if (!confirm(`Delete "${r.name}"?`)) return;
    const { error } = await supabase.from("sidebar_categories").delete().eq("id", r.id);
    if (error) toast.error(error.message); else onChange();
  };

  return (
    <Card className="p-3">
      <div className="grid grid-cols-1 sm:grid-cols-[1fr_140px_1fr_80px_auto_auto_auto] gap-2 items-end">
        <div><Label className="text-[10px]">Name</Label><Input value={r.name} onChange={(e) => setR({ ...r, name: e.target.value })} /></div>
        <div>
          <Label className="text-[10px]">Icon</Label>
          <select value={r.icon ?? ""} onChange={(e) => setR({ ...r, icon: e.target.value })} className="w-full h-9 rounded-md border border-input bg-background px-2 text-sm">
            <option value="">(none)</option>
            {ICON_KEYS.map((k) => <option key={k} value={k}>{k}</option>)}
          </select>
        </div>
        <div><Label className="text-[10px]">Link</Label><Input value={r.link ?? ""} onChange={(e) => setR({ ...r, link: e.target.value })} placeholder="/matches or https://" /></div>
        <div><Label className="text-[10px]">Order</Label><Input type="number" value={r.sort_order} onChange={(e) => setR({ ...r, sort_order: Number(e.target.value) })} /></div>
        <div className="flex items-center gap-1"><Switch checked={r.is_pinned} onCheckedChange={(v) => setR({ ...r, is_pinned: v })} /><Label className="text-[10px]">Pin</Label></div>
        <div className="flex items-center gap-1"><Switch checked={r.is_active} onCheckedChange={(v) => setR({ ...r, is_active: v })} /><Label className="text-[10px]">On</Label></div>
        <div className="flex gap-1">
          <Button size="sm" variant="destructive" onClick={del}><Trash2 className="h-4 w-4" /></Button>
          <Button size="sm" className="btn-luxury" disabled={saving} onClick={save}><Save className="h-4 w-4" /></Button>
        </div>
      </div>
    </Card>
  );
}
