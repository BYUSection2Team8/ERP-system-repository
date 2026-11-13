import { db, unwrap } from '../../lib/db';
import { useLiveQuery } from '../../lib/useLiveQuery';
import type { BomLine, Item, Location, MoStatus, ReasonCode, Setting, StandardCost } from '../../lib/types';

// Shared pieces for the production screens. Costs, plates and metrics come
// from the database (004/008 functions and views); screens only display them.

export const moStatusLabels: Record<MoStatus, string> = {
  planned: 'Planned',
  in_progress: 'In progress',
  completed: 'Completed',
  cancelled: 'Cancelled',
};

export function MoStatusBadge({ status }: { status: MoStatus }) {
  const tone = status === 'planned' ? 'warn' : status === 'in_progress' ? 'warn' : status === 'completed' ? 'ok' : '';
  return <span className={`badge status ${tone}`}>{moStatusLabels[status]}</span>;
}

export function pctText(v: number | string | null | undefined, digits = 1): string {
  if (v === null || v === undefined) return '—';
  return `${(Number(v) * 100).toFixed(digits)}%`;
}

export function hoursText(v: number | string | null | undefined): string {
  if (v === null || v === undefined) return '—';
  const h = Number(v);
  if (h < 1) return `${Math.round(h * 60)} min`;
  return `${h.toFixed(1)} h`;
}

/** Today's business date in Utah as YYYY-MM-DD. */
export function localToday(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Denver' }).format(new Date());
}

export function addDays(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T12:00:00`);
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

/** <input type="datetime-local"> value for "now" in the browser's time zone. */
export function nowLocalInput(): string {
  const d = new Date();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}

export interface ProductionRefData {
  items: Item[];
  itemsById: Map<string, Item>;
  /** Items that have a bill of material (we make them). */
  makeable: Item[];
  locations: Location[];
  scrapReasons: ReasonCode[];
  bom: Map<string, BomLine[]>;
  standardCost: Map<string, StandardCost>;
  settings: Map<string, number>;
  machineRate: number;
}

async function loadRef(): Promise<ProductionRefData> {
  const c = db();
  const [items, locations, reasons, bom, std, settings, rate] = await Promise.all([
    c.from('items').select('*').eq('is_active', true).order('name').then(unwrap<Item[]>),
    c.from('locations').select('*').eq('is_active', true).order('sort_order').then(unwrap<Location[]>),
    c.from('reason_codes').select('*').eq('category', 'scrap').eq('is_active', true).order('sort_order').then(unwrap<ReasonCode[]>),
    c.from('v_bom_per_unit').select('*').then(unwrap<BomLine[]>),
    c.from('v_item_standard_cost').select('*').then(unwrap<StandardCost[]>),
    c.from('settings').select('key, value').in('key', ['labor_rate', 'setup_minutes_per_plate', 'cleanup_minutes_per_plate']).then(unwrap<Setting[]>),
    c.rpc('machine_rate_per_hour').then((r) => Number(unwrap<number>(r) ?? 0)),
  ]);
  const bomMap = new Map<string, BomLine[]>();
  for (const b of bom) bomMap.set(b.parent_item_id, [...(bomMap.get(b.parent_item_id) ?? []), b]);
  return {
    items,
    itemsById: new Map(items.map((i) => [i.id, i])),
    makeable: items.filter((i) => bomMap.has(i.id)),
    locations,
    scrapReasons: reasons,
    bom: bomMap,
    standardCost: new Map(std.map((s) => [s.item_id, s])),
    settings: new Map(settings.map((s) => [s.key, Number(s.value)])),
    machineRate: rate,
  };
}

/** Items, BOMs, scrap reasons, standard costs and cost settings (live). */
export function useProductionRefData() {
  return useLiveQuery(loadRef, ['items', 'settings', 'inventory_txn']);
}
