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
  tracking_token: string | null;
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
  shipping?: { zone: number; weight_oz: number; postage: number; handling: number; total: number } | null;
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

// ---------------------------------------------------------------------------
// Production (Phase 5)
// ---------------------------------------------------------------------------
export type MoStatus = 'planned' | 'in_progress' | 'completed' | 'cancelled';

export interface ProductionOrder {
  id: string;
  mo_no: string;
  item_id: string;
  qty_planned: number;
  plates: number;
  location_id: string;
  output_location_id: string;
  status: MoStatus;
  so_id: string | null;
  printer_id: string | null;
  due_date: string | null;
  qty_started: number;
  qty_good: number;
  qty_scrap: number;
  scrap_reason: string | null;
  started_at: string | null;
  finished_at: string | null;
  material_cost: number;
  labor_cost: number;
  machine_cost: number;
  unit_cost: number | null;
  notes: string | null;
  created_by: string | null;
  created_at: string;
}

export interface ProductionOrderComponent {
  mo_id: string;
  item_id: string;
  qty_required: number;
  qty_issued: number;
  unit_cost: number | null;
}

/** v_production_orders: an order plus its derived report measures. */
export interface ProductionOrderRow {
  id: string;
  mo_no: string;
  item_id: string;
  sku: string;
  item_name: string;
  product_family: string | null;
  status: MoStatus;
  qty_planned: number;
  plates: number;
  qty_started: number;
  qty_good: number;
  qty_scrap: number;
  scrap_reason: string | null;
  so_id: string | null;
  due_date: string | null;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  material_cost: number;
  machine_cost: number;
  labor_cost: number;
  unit_cost: number | null;
  scrap_cost: number;
  report_date: string;
  cycle_hours: number | null;
  on_time: boolean | null;
}

export interface ProductionMetrics {
  orders_in_range: number;
  orders_completed: number;
  orders_open: number;
  qty_started: number;
  qty_good: number;
  qty_scrap: number;
  first_pass_yield: number | null;
  unit_yield: number | null;
  scrap_rate: number | null;
  avg_cycle_hours: number | null;
  orders_with_due: number;
  orders_on_time: number;
  on_time_rate: number | null;
  scrap_cost: number;
  production_cost: number;
}

export interface StandardCost {
  item_id: string;
  sku: string;
  name: string;
  price: number | null;
  material_cost: number;
  machine_cost: number;
  labor_cost: number;
  total_cost: number;
  margin_pct: number | null;
}

export interface BomLine {
  parent_item_id: string;
  component_item_id: string;
  qty_per_plate: number;
  units_per_plate: number;
  qty_per_unit: number;
}

// ---------------------------------------------------------------------------
// MRP (Phase 5)
// ---------------------------------------------------------------------------
export interface MrpParentRow {
  item_id: string;
  week_no: number;
  week_start: string;
  gross_demand: number;
  on_hand: number;
  scheduled_output: number;
  projected_balance: number;
  net_requirement: number;
  planned_plates: number;
  planned_qty: number;
  need_date: string | null;
  start_by: string | null;
  lead_days: number;
}

export interface MrpComponentRow {
  item_id: string;
  week_no: number;
  week_start: string;
  gross_requirement: number;
  scheduled_receipts: number;
  on_hand: number;
  projected_balance: number;
  net_requirement: number;
  planned_order_qty: number;
  planned_order_units: number;
  purchase_uom: string;
  stock_per_purchase_unit: number;
  need_date: string | null;
  order_by_date: string | null;
  lead_days: number;
  supplier_id: string | null;
  unit_cost: number | null;
}

// ---------------------------------------------------------------------------
// Purchasing (Phase 7)
// ---------------------------------------------------------------------------
export interface Supplier {
  id: string;
  name: string;
  contact_name: string | null;
  email: string | null;
  phone: string | null;
  website: string | null;
  address: string | null;
  quoted_lead_days: number;
  payment_terms: string;
  terms_days: number;
  notes: string | null;
  is_active: boolean;
}

export interface ItemSupplier {
  item_id: string;
  supplier_id: string;
  supplier_part_no: string | null;
  purchase_uom: string;
  stock_per_purchase_unit: number;
  unit_cost: number;
  lead_time_days: number | null;
  min_order_qty: number;
  is_preferred: boolean;
}

export type PoStatus = 'draft' | 'sent' | 'partial' | 'received' | 'closed' | 'cancelled';

export interface PurchaseOrder {
  id: string;
  po_no: string;
  supplier_id: string;
  status: PoStatus;
  ship_to_location_id: string;
  order_date: string | null;
  lead_days: number | null;
  expected_date: string | null;
  terms_days: number;
  source: 'manual' | 'mrp' | 'reorder' | 'review';
  notes: string | null;
  closed_at: string | null;
  created_by: string | null;
  created_at: string;
}

export interface PurchaseOrderLine {
  id: string;
  po_id: string;
  line_no: number;
  item_id: string;
  qty_ordered: number;
  purchase_uom: string;
  stock_per_purchase_unit: number;
  unit_cost: number;
  qty_received: number;
  need_date: string | null;
}

export interface PoReceipt {
  id: string;
  po_id: string;
  received_at: string;
  location_id: string;
  amount: number;
  due_date: string | null;
  notes: string | null;
}

export interface ApOpen {
  receipt_id: string;
  po_id: string;
  po_no: string;
  supplier_id: string;
  supplier_name: string;
  received_at: string;
  due_date: string | null;
  amount: number;
  amount_paid: number;
  balance: number;
  is_overdue: boolean;
}

// ---------------------------------------------------------------------------
// Returns and financials (Phase 8)
// ---------------------------------------------------------------------------
export interface SaleReturn {
  id: string;
  return_no: string;
  so_id: string;
  customer_id: string | null;
  return_type: 'refund' | 'exchange';
  returned_at: string;
  merchandise_credit: number;
  tax_credit: number;
  restocking_fee: number;
  exchange_so_id: string | null;
  exchange_total: number;
  refund_amount: number;
  notes: string | null;
  created_by: string | null;
}

export interface ReturnLine {
  id: string;
  return_id: string;
  so_line_id: string;
  item_id: string;
  qty: number;
  reason_code: string;
  disposition: 'restock' | 'qa_hold';
  location_id: string;
  net_unit_price: number;
  unit_cost: number;
}

/** What quote_return returns: the return priced but not saved. */
export interface ReturnQuote {
  return_type: 'refund' | 'exchange';
  merchandise_credit: number;
  tax_credit: number;
  restocking_fee: number;
  exchange_total: number;
  refund_amount: number;
  refund_to: string;
  exchange: { subtotal: number; discount_amount: number; tax_amount: number; total: number; will_ship_now: boolean } | null;
  lines: { so_line_id: string; item_id: string; qty: number; reason_code: string; disposition: 'restock' | 'qa_hold'; location_id: string; net_unit_price: number; unit_cost: number }[];
}

export interface PlLine {
  line_no: number;
  label: string;
  account_code: string | null;
  amount: number;
  kind: 'line' | 'subtotal' | 'total';
}

export interface Turnover {
  cogs: number;
  begin_inventory: number;
  end_inventory: number;
  avg_inventory: number;
  days: number;
  turnover: number | null;
  annualized_turnover: number | null;
  days_of_inventory: number | null;
}
