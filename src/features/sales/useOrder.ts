import { db, unwrap } from '../../lib/db';
import type { Account, Backorder, Customer, Item, LedgerRow, Location, SalesOrder, SalesOrderLine } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';

export interface OrderLineView extends SalesOrderLine {
  item: Pick<Item, 'id' | 'sku' | 'barcode' | 'name' | 'uom'>;
}

export interface ReturnSummary {
  id: string;
  return_no: string;
  return_type: 'refund' | 'exchange';
  returned_at: string;
  refund_amount: number;
  exchange_so_id: string | null;
}

export interface OrderView {
  order: SalesOrder;
  lines: OrderLineView[];
  customer: Customer | null;
  location: Location;
  reasonText: string | null;
  cashier: string | null;
  ledger: LedgerRow[];
  accounts: Map<string, Account>;
  backorders: Backorder[];
  returns: ReturnSummary[];
  /** Stock on hand / available at the order's location, per item. */
  stock: Map<string, { on_hand: number; available: number }>;
}

async function loadOrder(id: string): Promise<OrderView> {
  const c = db();
  const order = await c.from('sales_orders').select('*').eq('id', id).maybeSingle().then(unwrap<SalesOrder | null>);
  if (!order) throw new Error('That sales order does not exist.');
  const [lines, customer, location, reason, cashier, ledger, accounts, backorders, returns, stock] = await Promise.all([
    c.from('sales_order_lines')
      .select('*, item:items(id, sku, barcode, name, uom)')
      .eq('so_id', id)
      .order('line_no')
      // item_id is a foreign key, so PostgREST embeds one object, not an array.
      .then((r) => unwrap(r) as unknown as OrderLineView[]),
    order.customer_id
      ? c.from('customers').select('*').eq('id', order.customer_id).maybeSingle().then(unwrap<Customer | null>)
      : Promise.resolve(null),
    c.from('locations').select('*').eq('id', order.location_id).single().then(unwrap<Location>),
    order.discount_reason
      ? c.from('reason_codes').select('description').eq('code', order.discount_reason).maybeSingle().then(unwrap<{ description: string } | null>)
      : Promise.resolve(null),
    order.created_by
      ? c.from('profiles').select('full_name').eq('id', order.created_by).maybeSingle()
          .then((r) => (r.error ? null : ((r.data as { full_name: string | null } | null)?.full_name ?? null)))
      : Promise.resolve(null),
    c.from('ledger')
      .select('id, journal_id, posted_at, account_code, debit, credit, source_type, memo')
      .eq('source_id', id)
      .order('posted_at')
      .order('id')
      .then(unwrap<LedgerRow[]>),
    c.from('accounts').select('code, name, type').then(unwrap<Account[]>),
    c.from('v_backorders').select('*').eq('so_id', id).then(unwrap<Backorder[]>),
    c.from('returns')
      .select('id, return_no, return_type, returned_at, refund_amount, exchange_so_id')
      .eq('so_id', id)
      .order('returned_at')
      .then(unwrap<ReturnSummary[]>),
    c.from('v_availability')
      .select('item_id, qty_on_hand, qty_available')
      .eq('location_id', order.location_id)
      .then(unwrap<{ item_id: string; qty_on_hand: number; qty_available: number }[]>),
  ]);
  return {
    order,
    lines,
    customer,
    location,
    reasonText: reason?.description ?? null,
    cashier,
    ledger,
    accounts: new Map(accounts.map((a) => [a.code, a])),
    backorders,
    returns,
    stock: new Map(stock.map((s) => [s.item_id, { on_hand: Number(s.qty_on_hand), available: Number(s.qty_available) }])),
  };
}

/** One sales order with everything its screens show; refreshes live. */
export function useOrder(id: string) {
  return useLiveQuery(
    () => loadOrder(id),
    ['sales_orders', 'sales_order_lines', 'ledger', 'inventory_txn', 'returns'],
    [id],
  );
}
