import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Switch } from "@/components/ui/switch";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { toast } from "sonner";
import { Plus, Save, Trash2, ArrowUp, ArrowDown, Home } from "lucide-react";

const db: any = supabase;

type FieldType = "text" | "textarea" | "url" | "image" | "number" | "datetime" | "bool" | "select" | "numarr";
type Field = {
  key: string;
  label: string;
  type: FieldType;
  placeholder?: string;
  options?: { value: string; label: string }[];
};

const SECTIONS: Array<{
  key: string;
  table: string;
  label: string;
  description: string;
  fields: Field[];
}> = [
  {
    key: "hero",
    table: "home_hero_slides",
    label: "Hero Banners",
    description: "Top rotating carousel above the homepage.",
    fields: [
      { key: "image_url", label: "Image URL", type: "image", placeholder: "https://…" },
      { key: "title", label: "Title", type: "text" },
      { key: "subtitle", label: "Subtitle", type: "text" },
      { key: "cta_label", label: "CTA Label", type: "text" },
      { key: "cta_url", label: "CTA URL", type: "url" },
    ],
  },
  {
    key: "popular",
    table: "home_popular_links",
    label: "Popular Rail",
    description: "Left-side quick links (Popular, Today's, World Cup, …).",
    fields: [
      { key: "label", label: "Label", type: "text" },
      { key: "target_url", label: "Target URL", type: "url" },
      { key: "icon", label: "Icon (optional)", type: "text" },
    ],
  },
  {
    key: "featured",
    table: "home_featured_tiles",
    label: "Featured / Highlight / Gifts",
    description: "Three tabbed tile rows on the homepage.",
    fields: [
      {
        key: "tab",
        label: "Tab",
        type: "select",
        options: [
          { value: "featured", label: "Featured Games" },
          { value: "highlight", label: "Highlight" },
          { value: "gifts", label: "Gifts" },
        ],
      },
      { key: "image_url", label: "Image URL", type: "image" },
      { key: "title", label: "Title", type: "text" },
      { key: "cta_label", label: "CTA Label", type: "text" },
      { key: "cta_url", label: "CTA URL", type: "url" },
    ],
  },
  {
    key: "news",
    table: "home_news_posts",
    label: "News",
    description: "News cards shown in the homepage cluster.",
    fields: [
      { key: "image_url", label: "Image URL", type: "image" },
      { key: "title", label: "Title", type: "text" },
      { key: "body", label: "Body", type: "textarea" },
      { key: "link_url", label: "Link URL", type: "url" },
    ],
  },
  {
    key: "draws",
    table: "home_lottery_draws",
    label: "Lottery Draws",
    description: "Live / upcoming lottery draws with countdown and CTA.",
    fields: [
      { key: "name", label: "Name", type: "text", placeholder: "5/90, Quick 3…" },
      { key: "prize_label", label: "Prize", type: "text", placeholder: "₦2,950,000" },
      { key: "ends_at", label: "Ends At", type: "datetime" },
      { key: "cta_label", label: "CTA Label", type: "text", placeholder: "Buy Now" },
      { key: "cta_url", label: "CTA URL", type: "url" },
      { key: "numbers", label: "Numbers (comma-separated)", type: "numarr" },
    ],
  },
  {
    key: "results",
    table: "home_lottery_results",
    label: "Lottery Results",
    description: "Past draw results with winning numbers.",
    fields: [
      { key: "draw_name", label: "Draw", type: "text", placeholder: "5/90" },
      { key: "draw_no", label: "Draw No.", type: "text" },
      { key: "numbers", label: "Numbers (comma-separated)", type: "numarr" },
      { key: "winnings_label", label: "Winnings", type: "text", placeholder: "₦2,950,000.00" },
    ],
  },
];

export function HomepageAdminPanel() {
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <Home className="h-5 w-5 text-primary" />
        <h2 className="text-lg font-bold">Homepage</h2>
      </div>
      <p className="text-xs text-muted-foreground">
        Manage every section on the homepage: hero carousel, popular rail, featured / highlight / gifts tiles, news, lottery draws, and lottery results.
      </p>
      <Tabs defaultValue={SECTIONS[0].key}>
        <TabsList className="flex flex-wrap h-auto">
          {SECTIONS.map((s) => (
            <TabsTrigger key={s.key} value={s.key} className="text-xs">{s.label}</TabsTrigger>
          ))}
        </TabsList>
        {SECTIONS.map((s) => (
          <TabsContent key={s.key} value={s.key} className="mt-4">
            <SectionEditor section={s} />
          </TabsContent>
        ))}
      </Tabs>
    </div>
  );
}

function SectionEditor({ section }: { section: typeof SECTIONS[number] }) {
  const [rows, setRows] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);

  const load = async () => {
    setLoading(true);
    const { data, error } = await db.from(section.table).select("*").order("sort_order", { ascending: true });
    if (error) toast.error(error.message);
    setRows(data ?? []);
    setLoading(false);
  };

  useEffect(() => { load(); }, [section.table]);

  const addNew = async () => {
    const defaults: any = { sort_order: (rows[rows.length - 1]?.sort_order ?? 0) + 1, is_active: true };
    for (const f of section.fields) {
      if (f.type === "select" && f.options) defaults[f.key] = f.options[0].value;
      else if (f.type === "numarr") defaults[f.key] = [];
      else if (f.type === "bool") defaults[f.key] = true;
      else defaults[f.key] = null;
    }
    // Fill required fields with placeholder to satisfy NOT NULL
    if (section.table === "home_hero_slides") defaults.image_url = defaults.image_url ?? "https://placehold.co/1200x500/000/fff?text=New+Slide";
    if (section.table === "home_featured_tiles") defaults.image_url = defaults.image_url ?? "https://placehold.co/400x300/000/fff?text=Tile";
    if (section.table === "home_popular_links") { defaults.label = defaults.label ?? "New Link"; defaults.target_url = defaults.target_url ?? "/matches"; }
    if (section.table === "home_news_posts") defaults.title = defaults.title ?? "New Post";
    if (section.table === "home_lottery_draws") defaults.name = defaults.name ?? "New Draw";
    if (section.table === "home_lottery_results") defaults.draw_name = defaults.draw_name ?? "New Result";

    const { error } = await db.from(section.table).insert(defaults);
    if (error) return toast.error(error.message);
    toast.success("Added");
    load();
  };

  const save = async (row: any) => {
    const { id, created_at, updated_at, ...rest } = row;
    const { error } = await db.from(section.table).update(rest).eq("id", id);
    if (error) return toast.error(error.message);
    toast.success("Saved");
  };

  const del = async (id: string) => {
    if (!confirm("Delete this entry?")) return;
    const { error } = await db.from(section.table).delete().eq("id", id);
    if (error) return toast.error(error.message);
    toast.success("Deleted");
    load();
  };

  const move = async (row: any, dir: -1 | 1) => {
    const idx = rows.findIndex((r) => r.id === row.id);
    const swap = rows[idx + dir];
    if (!swap) return;
    await db.from(section.table).update({ sort_order: swap.sort_order }).eq("id", row.id);
    await db.from(section.table).update({ sort_order: row.sort_order }).eq("id", swap.id);
    load();
  };

  const updateLocal = (id: string, key: string, value: any) => {
    setRows((rs) => rs.map((r) => (r.id === id ? { ...r, [key]: value } : r)));
  };

  return (
    <div className="space-y-3">
      <div className="flex justify-between items-center">
        <p className="text-xs text-muted-foreground">{section.description}</p>
        <Button size="sm" onClick={addNew}><Plus className="h-3.5 w-3.5 mr-1" />Add</Button>
      </div>
      {loading && <p className="text-sm text-muted-foreground">Loading…</p>}
      {!loading && rows.length === 0 && (
        <Card className="p-6 text-center text-sm text-muted-foreground">No entries yet. Click Add to create one.</Card>
      )}
      <div className="space-y-3">
        {rows.map((row, idx) => (
          <Card key={row.id} className="p-3 space-y-2">
            <div className="flex justify-between gap-2 items-start">
              <div className="flex items-center gap-2">
                <Switch checked={!!row.is_active} onCheckedChange={(v) => { updateLocal(row.id, "is_active", v); db.from(section.table).update({ is_active: v }).eq("id", row.id).then(() => toast.success(v ? "Enabled" : "Disabled")); }} />
                <span className="text-[10px] uppercase tracking-widest text-muted-foreground">{row.is_active ? "Active" : "Hidden"}</span>
              </div>
              <div className="flex items-center gap-1">
                <Button size="sm" variant="outline" disabled={idx === 0} onClick={() => move(row, -1)}><ArrowUp className="h-3 w-3" /></Button>
                <Button size="sm" variant="outline" disabled={idx === rows.length - 1} onClick={() => move(row, 1)}><ArrowDown className="h-3 w-3" /></Button>
                <Button size="sm" variant="outline" onClick={() => save(row)}><Save className="h-3 w-3 mr-1" />Save</Button>
                <Button size="sm" variant="destructive" onClick={() => del(row.id)}><Trash2 className="h-3 w-3" /></Button>
              </div>
            </div>
            <div className="grid md:grid-cols-2 gap-2">
              {section.fields.map((f) => (
                <FieldInput key={f.key} field={f} value={row[f.key]} onChange={(v) => updateLocal(row.id, f.key, v)} />
              ))}
            </div>
          </Card>
        ))}
      </div>
    </div>
  );
}

function FieldInput({ field, value, onChange }: { field: Field; value: any; onChange: (v: any) => void }) {
  if (field.type === "textarea") {
    return (
      <div className="space-y-1 md:col-span-2">
        <Label className="text-xs">{field.label}</Label>
        <Textarea value={value ?? ""} placeholder={field.placeholder} onChange={(e) => onChange(e.target.value)} rows={2} />
      </div>
    );
  }
  if (field.type === "select" && field.options) {
    return (
      <div className="space-y-1">
        <Label className="text-xs">{field.label}</Label>
        <Select value={value ?? field.options[0].value} onValueChange={onChange}>
          <SelectTrigger><SelectValue /></SelectTrigger>
          <SelectContent>
            {field.options.map((o) => <SelectItem key={o.value} value={o.value}>{o.label}</SelectItem>)}
          </SelectContent>
        </Select>
      </div>
    );
  }
  if (field.type === "numarr") {
    return (
      <div className="space-y-1 md:col-span-2">
        <Label className="text-xs">{field.label}</Label>
        <Input
          value={Array.isArray(value) ? value.join(", ") : ""}
          placeholder="e.g. 9, 31, 41, 4, 80"
          onChange={(e) => {
            const arr = e.target.value.split(",").map((s) => Number(s.trim())).filter((n) => !isNaN(n));
            onChange(arr);
          }}
        />
      </div>
    );
  }
  if (field.type === "datetime") {
    const iso = value ? new Date(value).toISOString().slice(0, 16) : "";
    return (
      <div className="space-y-1">
        <Label className="text-xs">{field.label}</Label>
        <Input type="datetime-local" value={iso} onChange={(e) => onChange(e.target.value ? new Date(e.target.value).toISOString() : null)} />
      </div>
    );
  }
  return (
    <div className="space-y-1">
      <Label className="text-xs">{field.label}</Label>
      <Input type={field.type === "number" ? "number" : "text"} value={value ?? ""} placeholder={field.placeholder} onChange={(e) => onChange(e.target.value)} />
      {field.type === "image" && value && <img src={value} alt="" className="h-16 rounded border border-border/50 object-cover" />}
    </div>
  );
}
