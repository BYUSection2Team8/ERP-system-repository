import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, shortLocation } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { date, qty } from '../../lib/format';
import type { Backorder, Item, Location } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';

interface Data {
  rows: Backorder[];
  items: Map<string, Item>;
  customers: Map<string, string>;
  locations: Map<string, Location>;
}

async function load(): Promise<Data> {
  const c = db();
  const [rows, items, customers, locations] = await Promise.all([
    c.from('v_backorders').select('*').order('order_date').then(unwrap<Backorder[]>),
    c.from('items').select('*').then(unwrap<Item[]>),
    c.from('customers').select('id, name').then(unwrap<{ id: string; name: string }[]>),
    c.from('locations').select('*').then(unwrap<Location[]>),
  ]);
  return {
    rows,
    items: new Map(items.map((i) => [i.id, i])),
    customers: new Map(customers.map((x) => [x.id, x.name])),
    locations: new Map(locations.map((l) => [l.id, l])),
  };
}

export function BackordersPage() {
  const { data, error, loading } = useLiveQuery(load, [
    'sales_orders',
    'sales_order_lines',
    'inventory_txn',
    'purchase_orders',
    'production_orders',
  ]);

  if (loading) return <Loading what="backorders" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;

  return (
    <div>
      <PageHeader
        title="Backorders"
        subtitle="Open order lines that stock at their location can't cover yet, first come first served. The estimated date comes from open purchase orders or production orders, otherwise today + lead time."
      />
      {data.rows.length === 0 ? (
        <div className="card muted">Nothing is backordered. Every open order can be filled from stock.</div>
      ) : (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Order</th><th>Customer</th><th>Item</th><th>Ships from</th>
                <th className="num">Open qty</th><th className="num">On hand</th><th className="num">Backordered</th>
                <th>Needed by</th><th>Est. available</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((r) => {
                const item = data.items.get(r.item_id);
                const loc = data.locations.get(r.location_id);
                const late = r.need_date && r.est_available_date && r.est_available_date > r.need_date;
                return (
                  <tr key={r.so_line_id}>
                    <td>{r.order_no}<div className="muted small">{date(r.order_date)}</div></td>
                    <td>{(r.customer_id && data.customers.get(r.customer_id)) || 'Walk-in'}</td>
                    <td>{item ? <Link to={`/inventory/item/${item.id}`}>{item.name}</Link> : '?'}</td>
                    <td>{loc ? shortLocation(loc) : '?'}</td>
                    <td className="num">{qty(r.qty_open, item?.uom)}</td>
                    <td className="num">{qty(r.qty_on_hand, item?.uom)}</td>
                    <td className="num bad strong">{qty(r.qty_backordered, item?.uom)}</td>
                    <td>{date(r.need_date)}</td>
                    <td className={late ? 'bad' : ''}>{date(r.est_available_date)}{late && <div className="small">after need date</div>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
