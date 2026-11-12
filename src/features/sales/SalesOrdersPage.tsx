import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat, shortLocation } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { date, money } from '../../lib/format';
import type { Location, SalesOrder, SoStatus } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { channelLabels, methodLabels, StatusBadge } from './salesShared';

type Tab = SoStatus | 'all';
const tabs: { key: Tab; label: string }[] = [
  { key: 'placed', label: 'Placed' },
  { key: 'fulfilled', label: 'Fulfilled' },
  { key: 'closed', label: 'Closed' },
  { key: 'cancelled', label: 'Cancelled' },
  { key: 'all', label: 'All' },
];
const statuses: SoStatus[] = ['placed', 'fulfilled', 'closed', 'cancelled'];
const LIMIT = 200;

async function load(tab: Tab) {
  const c = db();
  let q = c.from('sales_orders').select('*');
  if (tab !== 'all') q = q.eq('status', tab);
  const [orders, counts, openValue, customers, locations, backorders] = await Promise.all([
    q.order('order_date', { ascending: false }).limit(LIMIT).then(unwrap<SalesOrder[]>),
    Promise.all(
      statuses.map((s) =>
        c.from('sales_orders').select('id', { count: 'exact', head: true }).eq('status', s).then((r) => {
          if (r.error) throw new Error(r.error.message);
          return [s, r.count ?? 0] as const;
        }),
      ),
    ),
    c.from('sales_orders').select('total').eq('status', 'placed').then(unwrap<{ total: number }[]>),
    c.from('customers').select('id, name').then(unwrap<{ id: string; name: string }[]>),
    c.from('locations').select('*').then(unwrap<Location[]>),
    c.from('v_backorders').select('so_id').then(unwrap<{ so_id: string }[]>),
  ]);
  return {
    orders,
    counts: new Map<SoStatus, number>(counts),
    openValue: openValue.reduce((s, o) => s + Number(o.total), 0),
    customers: new Map(customers.map((x) => [x.id, x.name])),
    locations: new Map(locations.map((l) => [l.id, l])),
    backordered: new Set(backorders.map((b) => b.so_id)),
  };
}

export function SalesOrdersPage() {
  const [tab, setTab] = useState<Tab>('placed');
  const [search, setSearch] = useState('');
  const navigate = useNavigate();
  const { data, error, loading } = useLiveQuery(
    () => load(tab),
    ['sales_orders', 'sales_order_lines', 'inventory_txn', 'customers'],
    [tab],
  );

  const rows = useMemo(() => {
    if (!data) return [];
    const t = search.trim().toLowerCase();
    if (!t) return data.orders;
    return data.orders.filter(
      (o) =>
        o.order_no.toLowerCase().includes(t) ||
        (o.customer_id ? data.customers.get(o.customer_id) ?? '' : 'walk-in').toLowerCase().includes(t),
    );
  }, [data, search]);

  return (
    <div>
      <PageHeader
        title="Sales orders"
        subtitle="Every order moves Order placed → Fulfilled → Closed, or is Cancelled before it is fulfilled. POS sales are created, fulfilled and closed in one step."
        actions={
          <>
            <Link className="btn primary" to="/sales/new">New sales order</Link>
            <Link className="btn" to="/pos">Point of sale</Link>
          </>
        }
      />
      {loading && <Loading what="sales orders" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Open orders (placed)" value={data.counts.get('placed') ?? 0} hint={`${money(data.openValue)} not yet fulfilled`} />
            <Stat
              label="Backordered orders"
              value={data.backordered.size}
              tone={data.backordered.size > 0 ? 'warn' : undefined}
              hint={<Link to="/inventory/backorders">View backorders</Link>}
            />
            <Stat label="Fulfilled, not closed" value={data.counts.get('fulfilled') ?? 0} hint="Delivered, waiting to close" />
            <Stat label="Closed orders" value={data.counts.get('closed') ?? 0} />
          </div>

          <div className="toolbar">
            <div className="tabs">
              {tabs.map((t) => (
                <button key={t.key} className={tab === t.key ? 'active' : ''} onClick={() => setTab(t.key)}>
                  {t.label}
                  {t.key !== 'all' && <span className="tab-count">{data.counts.get(t.key) ?? 0}</span>}
                </button>
              ))}
            </div>
            <input className="grow" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search order number or customer" aria-label="Search orders" />
          </div>

          {rows.length === 0 ? (
            <div className="card muted">No orders here.</div>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Order</th>
                    <th>Date</th>
                    <th>Customer</th>
                    <th>Channel</th>
                    <th>From</th>
                    <th>Need by</th>
                    <th>Status</th>
                    <th className="num">Total</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((o) => {
                    const loc = data.locations.get(o.location_id);
                    return (
                      <tr key={o.id} className="clickable" onClick={() => navigate(`/sales/${o.id}`)}>
                        <td className="strong"><Link to={`/sales/${o.id}`} onClick={(e) => e.stopPropagation()}>{o.order_no}</Link></td>
                        <td>{date(o.order_date)}</td>
                        <td>{(o.customer_id && data.customers.get(o.customer_id)) || <span className="muted">Walk-in</span>}</td>
                        <td>{channelLabels[o.channel]}<div className="muted small">{methodLabels[o.fulfillment_method]}</div></td>
                        <td>{loc ? shortLocation(loc) : '?'}</td>
                        <td>{o.status === 'placed' ? date(o.need_date) : '—'}</td>
                        <td><StatusBadge status={o.status} backordered={data.backordered.has(o.id)} /></td>
                        <td className="num">{money(o.total)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
          {data.orders.length === LIMIT && <p className="muted small">Showing the latest {LIMIT}. Search narrows within these.</p>}
        </>
      )}
    </div>
  );
}
