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

export interface Customer {
  id: string;
  customer_no: string;
  name: string;
  contact_name: string | null;
  email: string | null;
  phone: string | null;
  city: string | null;
  state: string | null;
  segment: string | null;
  is_byu: boolean;
  terms_days: number;
  is_active: boolean;
}

export type SoStatus = 'placed' | 'fulfilled' | 'closed' | 'cancelled';
export type DiscountType = 'none' | 'byu' | 'business' | 'manual';
export type FulfillmentMethod = 'ship' | 'pickup' | 'counter';
export type PaymentMethod = 'cash' | 'card' | 'account' | 'exchange';

export interface SalesOrder {
  id: string;
  order_no: string;
  customer_id: string | null;
  channel: 'pos' | 'online' | 'phone' | 'portal';
  fulfillment_method: FulfillmentMethod;
  location_id: string;
  status: SoStatus;
  order_date: string;
  need_date: string | null;
  ship_state: string | null;
  discount_type: DiscountType;
  discount_pct: number;
  discount_reason: string | null;
  subtotal: number;
  discount_amount: number;
  shipping_amount: number;
  tax_rate: number;
  tax_amount: number;
  total: number;
  payment_method: PaymentMethod | null;
  customer_email: string | null;
  notes: string | null;
  fulfilled_at: string | null;
  closed_at: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  created_by: string | null;
  created_at: string;
}

export interface SalesOrderLine {
  id: string;
  so_id: string;
  line_no: number;
  item_id: string;
  qty: number;
  unit_price: number;
  net_unit_price: number;
  line_total: number;
  unit_cost: number | null;
  qty_fulfilled: number;
  qty_returned: number;
}

/** What quote_sales_order returns: the order priced but not saved. */
export interface Quote {
  customer_id: string | null;
  customer_name: string | null;
  channel: string;
  fulfillment_method: FulfillmentMethod;
  location_id: string;
  ship_state: string | null;
  tax_rate: number;
  payment_method: PaymentMethod;
  discount_type: DiscountType;
  discount_pct: number;
  discount_reason: string | null;
  units: number;
  subtotal: number;
  discount_amount: number;
  shipping_amount: number;
  tax_amount: number;
  total: number;
  need_date: string;
  customer_email: string | null;
  is_byu: boolean;
  terms_days: number;
  business_min_units: number;
  lines: {
    line_no: number;
    item_id: string;
    sku: string;
    name: string;
    qty: number;
    unit_price: number;
    net_unit_price: number;
    line_total: number;
  }[];
}

export interface LedgerRow {
  id: number;
  journal_id: string;
  posted_at: string;
  account_code: string;
  debit: number;
  credit: number;
  source_type: string;
  memo: string | null;
}

export interface Account {
  code: string;
  name: string;
  type: string;
}
