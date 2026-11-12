import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { dateTime, money } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';

interface Activity {
  id: number;
  at: string;
  actor: string | null;
  summary: string;
  link: string | null;
}

async function load() {
  const c = db();
  const [balances, backorders, activity, fg, openOrders] = await Promise.all([
    c.from('v_account_balances').select('code, balance').in('code', ['1200', '1250']).then(unwrap<{ code: string; balance: number }[]>),
    c.from('v_backorders').select('so_line_id').then(unwrap<{ so_line_id: string }[]>),
    c.from('activity_log').select('id, at, actor, summary, link').order('at', { ascending: false }).limit(10).then(unwrap<Activity[]>),
    c.from('v_inventory_valuation').select('qty_on_hand, category').eq('category', 'product').then(unwrap<{ qty_on_hand: number }[]>),
    c.from('sales_orders').select('total').eq('status', 'placed').then(unwrap<{ total: number }[]>),
  ]);
  const bal = (code: string) => Number(balances.find((b) => b.code === code)?.balance ?? 0);
  return {
    inventoryValue: bal('1200'),
    wipValue: bal('1250'),
    backorderLines: backorders.length,
    finishedUnits: fg.reduce((s, r) => s + Number(r.qty_on_hand), 0),
    openOrders: openOrders.length,
    openOrderValue: openOrders.reduce((s, o) => s + Number(o.total), 0),
    activity,
  };
}

export function DashboardPage() {
  const { data, error, loading } = useLiveQuery(load, ['inventory_txn', 'ledger', 'activity_log', 'sales_orders']);

  return (
    <div>
      <PageHeader title="Dashboard" subtitle="Live figures from the ledger and stock records." />
      {loading && <Loading />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Inventory on the books" value={money(data.inventoryValue)} hint="Ledger account 1200" />
            <Stat label="Work in process" value={money(data.wipValue)} hint="Ledger account 1250" />
            <Stat label="Finished units on hand" value={data.finishedUnits.toLocaleString()} />
            <Stat label="Open sales orders" value={data.openOrders} hint={<Link to="/sales">{money(data.openOrderValue)} to fulfill</Link>} />
            <Stat
              label="Backordered order lines"
              value={data.backorderLines}
              hint={<Link to="/inventory/backorders">View backorders</Link>}
              tone={data.backorderLines > 0 ? 'warn' : undefined}
            />
          </div>

          <h2>Recent activity</h2>
          {data.activity.length === 0 ? (
            <p className="muted">Nothing yet.</p>
          ) : (
            <ul className="activity">
              {data.activity.map((a) => (
                <li key={a.id}>
                  <span className="muted small">{dateTime(a.at)} · {a.actor ?? 'system'}</span>
                  <span>{a.link?.startsWith('/sales/') ? <Link to={a.link}>{a.summary}</Link> : a.summary}</span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  );
}
