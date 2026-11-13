import { db, unwrap } from '../../lib/db';
import type { Setting } from '../../lib/types';

/** One row of v_reorder_plan (010_purchasing_planning.sql). */
export interface ReorderRow {
  item_id: string;
  sku: string;
  name: string;
  category: string;
  item_type: 'finished' | 'purchased';
  uom: 'ea' | 'g';
  stocking_policy: string;
  replenish_by: 'purchase' | 'production';
  supplier_id: string | null;
  supplier_name: string | null;
  purchase_uom: string;
  pack: number;
  purchase_unit_cost: number | null;
  lead_days: number;
  days_observed: number;
  total_usage: number;
  avg_daily: number;
  sd_daily: number;
  annual_demand: number;
  unit_cost: number;
  carrying_rate: number;
  holding_cost_unit: number;
  order_cost: number;
  z: number;
  lead_time_demand: number;
  safety_stock: number;
  rop_calc: number;
  reorder_point_manual: number | null;
  reorder_point: number;
  eoq: number | null;
  eoq_units: number | null;
  on_hand: number;
  on_order: number;
  committed: number;
  position: number;
  below_reorder_point: boolean;
  days_of_supply: number | null;
  suggested_qty: number | null;
  suggested_units: number | null;
  order_by_date: string | null;
  review_interval_days: number;
  order_up_to: number;
  review_units: number | null;
  review_qty: number | null;
}

export async function loadReorderPlan() {
  const c = db();
  const [rows, settings] = await Promise.all([
    c.from('v_reorder_plan').select('*').order('name').then(unwrap<ReorderRow[]>),
    c.from('settings').select('key, value').in('key', ['ordering_cost', 'production_setup_cost', 'carrying_rate_annual', 'carrying_rate_seasonal', 'service_level_z', 'review_interval_days', 'demand_history_days']).then(unwrap<Setting[]>),
  ]);
  return { rows, settings: new Map(settings.map((s) => [s.key, Number(s.value)])) };
}

export const reorderTables = ['inventory_txn', 'purchase_orders', 'purchase_order_lines', 'production_orders', 'sales_orders', 'settings', 'items', 'inventory_reviews'];

export function n(v: number | string | null | undefined, digits = 2): string {
  if (v === null || v === undefined) return '—';
  return Number(v).toLocaleString('en-US', { maximumFractionDigits: digits });
}
