import { db, unwrap } from '../../lib/db';
import { useLiveQuery } from '../../lib/useLiveQuery';
import type { Availability, Item, Location, ReasonCode, Setting, Valuation } from '../../lib/types';

export interface InventoryData {
  items: Item[];
  locations: Location[];
  availability: Availability[];
  valuation: Map<string, Valuation>;
  reasons: ReasonCode[];
  spoolGrams: number;
  /** on hand / committed / available for one item at one location */
  at: (itemId: string, locationId: string) => Availability | undefined;
}

async function load(): Promise<InventoryData> {
  const client = db();
  const [items, locations, availability, valuation, reasons, settings] = await Promise.all([
    client.from('items').select('*').eq('is_active', true).order('category').order('name').then(unwrap<Item[]>),
    client.from('locations').select('*').eq('is_active', true).order('sort_order').then(unwrap<Location[]>),
    client.from('v_availability').select('*').then(unwrap<Availability[]>),
    client.from('v_inventory_valuation').select('item_id, qty_on_hand, avg_unit_cost, inventory_value').then(unwrap<Valuation[]>),
    client.from('reason_codes').select('*').eq('is_active', true).order('sort_order').then(unwrap<ReasonCode[]>),
    client.from('settings').select('key, value').eq('key', 'spool_grams').then(unwrap<Setting[]>),
  ]);
  const byKey = new Map(availability.map((a) => [`${a.item_id}|${a.location_id}`, a]));
  return {
    items,
    locations,
    availability,
    valuation: new Map(valuation.map((v) => [v.item_id, v])),
    reasons,
    spoolGrams: Number(settings[0]?.value ?? 985),
    at: (itemId, locationId) => byKey.get(`${itemId}|${locationId}`),
  };
}

/** Items, locations, stock and costs — refreshed live when stock moves anywhere. */
export function useInventoryData() {
  return useLiveQuery(load, ['inventory_txn', 'items', 'sales_orders', 'sales_order_lines', 'settings']);
}

export const categoryLabels: Record<string, string> = {
  product: 'Products',
  filament: 'Filament',
  component: 'Components',
  packaging: 'Packaging',
};
