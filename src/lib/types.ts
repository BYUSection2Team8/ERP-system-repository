// Row shapes returned by the database (see supabase/migrations).

export type ItemCategory = 'product' | 'filament' | 'component' | 'packaging';

export interface Item {
  id: string;
  sku: string;
  barcode: string;
  name: string;
  item_type: 'finished' | 'purchased';
  category: ItemCategory;
  product_family: string | null;
  color: string | null;
  uom: 'ea' | 'g';
  price: number | null;
  stocking_policy: 'stock' | 'make_to_order' | 'seasonal' | 'not_sold';
  units_per_plate: number;
  print_minutes: number | null;
  assembly_minutes: number | null;
  lead_time_days: number | null;
  preferred_supplier_id: string | null;
  is_active: boolean;
}

export interface Location {
  id: string;
  code: string;
  name: string;
  kind: string;
  is_sellable: boolean;
  sort_order: number;
}

export interface Availability {
  item_id: string;
  location_id: string;
  qty_on_hand: number;
  qty_committed: number;
  qty_available: number;
}

export interface Valuation {
  item_id: string;
  qty_on_hand: number;
  avg_unit_cost: number;
  inventory_value: number;
}

export interface ReasonCode {
  code: string;
  category: string;
  description: string;
  is_quality: boolean;
  sort_order: number;
}

export interface Backorder {
  so_line_id: string;
  so_id: string;
  order_no: string;
  customer_id: string | null;
  location_id: string;
  item_id: string;
  order_date: string;
  need_date: string | null;
  qty_open: number;
  qty_on_hand: number;
  qty_backordered: number;
  est_available_date: string | null;
}

export interface InventoryTxn {
  id: number;
  txn_at: string;
  item_id: string;
  location_id: string;
  qty: number;
  unit_cost: number;
  ext_cost: number;
  source_type: string;
  reason_code: string | null;
  note: string | null;
}

export interface Setting {
  key: string;
  value: string;
}
