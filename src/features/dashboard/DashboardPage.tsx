import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { dateTime, money } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { ShowMath } from '../../app/ShowMath';
import { DemandSimulator } from '../sales/DemandSimulator';
import { addDays, localToday } from '../production/productionShared';

interface Space {
  location_id: string;
  code: string;
  name: string;
  capacity_cuft: number | null;
  used_cuft: number;
  utilization: number | null;
  spools: number;
  rack_spools: number | null;
  rack_utilization: number | null;
  warn_pct: number;
}

function SpaceBar({ label, used, cap, share, warn, unit }: { label: string; used: number; cap: number | null; share: number | null; warn: number; unit: string }) {
  const s = Number(share ?? 0);
  const tone = s > 1 ? 'bad' : s > warn ? 'warn' : 'ok';
  return (
    <div className="space-row">
      <div className="space-label"><span>{label}</span><span className={tone === 'ok' ? 'muted' : tone === 'bad' ? 'bad strong' : 'strong'}>{(s * 100).toFixed(1)}%{tone === 'bad' ? ' · over capacity' : tone === 'warn' ? ' · nearly full' : ''}</span></div>
      <div className={`space-bar ${tone}`}><span style={{ width: `${Math.min(100, s * 100)}%` }} /></div>
      <div className="muted small">{used.toLocaleString(undefined, { maximumFractionDigits: 1 })} of {cap ?? '—'} {unit}</div>
    </div>
  );
}

interface Activity {
  id: number;
  at: string;
  actor: string | null;
  summary: string;
  link: string | null;
}

async function load() {
  const c = db();
  const today = localToday();
  const [balances, backorders, activity, fg, openOrders, week, low, space] = await Promise.all([
    c.from('v_account_balances').select('code, balance').in('code', ['1200', '1250']).then(unwrap<{ code: string; balance: number }[]>),
    c.from('v_backorders').select('so_line_id').then(unwrap<{ so_line_id: string }[]>),
    c.from('activity_log').select('id, at, actor, summary, link').order('at', { ascending: false }).limit(10).then(unwrap<Activity[]>),
    c.from('v_inventory_valuation').select('qty_on_hand, category').eq('category', 'product').then(unwrap<{ qty_on_hand: number }[]>),
    c.from('sales_orders').select('total').eq('status', 'placed').then(unwrap<{ total: number }[]>),
    c.rpc('sales_by_period', { p_from: addDays(today, -6), p_to: today, p_grain: 'day' }).then(unwrap<{ net_sales: number; orders: number }[]>),
    c.from('v_reorder_plan').select('item_id').eq('below_reorder_point', true).then(unwrap<{ item_id: string }[]>),
    c.from('v_location_utilization').select('*').then(unwrap<Space[]>),
  ]);
  const bal = (code: string) => Number(balances.find((b) => b.code === code)?.balance ?? 0);
  return {
    inventoryValue: bal('1200'),
    wipValue: bal('1250'),
    backorderLines: backorders.length,
    finishedUnits: fg.reduce((s, r) => s + Number(r.qty_on_hand), 0),
    openOrders: openOrders.length,
    openOrderValue: openOrders.reduce((s, o) => s + Number(o.total), 0),
    weekSales: week.reduce((s, r) => s + Number(r.net_sales), 0),
    weekOrders: week.reduce((s, r) => s + Number(r.orders), 0),
    lowStock: low.length,
    space,
    activity,
  };
}

export function DashboardPage() {
  const { data, error, loading } = useLiveQuery(load, ['inventory_txn', 'ledger', 'activity_log', 'sales_orders', 'purchase_orders', 'production_orders']);

  return (
    <div>
      <PageHeader title="Dashboard" subtitle="Live figures from the ledger and stock records." />
      {loading && <Loading />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Net sales, last 7 days" value={money(data.weekSales)} hint={<Link to="/reports">{data.weekOrders} orders · sales report</Link>} />
            <Stat label="Inventory on the books" value={money(data.inventoryValue)} hint="Ledger account 1200" />
            <Stat label="Work in process" value={money(data.wipValue)} hint="Ledger account 1250" />
            <Stat label="Finished units on hand" value={data.finishedUnits.toLocaleString()} />
            <Stat label="Items at reorder point" value={data.lowStock} hint={<Link to="/reports?tab=low">Low stock report</Link>} tone={data.lowStock > 0 ? 'warn' : undefined} />
            <Stat label="Open sales orders" value={data.openOrders} hint={<Link to="/sales">{money(data.openOrderValue)} to fulfill</Link>} />
            <Stat
              label="Backordered order lines"
              value={data.backorderLines}
              hint={<Link to="/inventory/backorders">View backorders</Link>}
              tone={data.backorderLines > 0 ? 'warn' : undefined}
            />
          </div>

          <DemandSimulator />

          <h2>Space used</h2>
          {(() => {
            const qa = data.space.find((s) => s.code === 'QA_HOLD');
            const warn = Number(data.space[0]?.warn_pct ?? 0.85);
            return (
              <div className="card space-card">
                {qa && Number(qa.utilization) > warn && <div className="notice warn">QA Hold is {(Number(qa.utilization) * 100).toFixed(0)}% full: inspection backlog. Inspect and clear returned items (Adjust &amp; count).</div>}
                {data.space.map((s) => (
                  <SpaceBar key={s.location_id} label={s.name} used={Number(s.used_cuft)} cap={s.capacity_cuft} share={s.utilization} warn={warn} unit="cu ft of finished goods" />
                ))}
                {data.space.filter((s) => s.rack_spools !== null).map((s) => (
                  <SpaceBar key={`rack-${s.location_id}`} label="Filament rack (Print Farm)" used={Number(s.spools)} cap={s.rack_spools} share={s.rack_utilization} warn={warn} unit="spools" />
                ))}
                <ShowMath
                  rows={[
                    { label: 'Space used = Σ (length × width × height in inches ÷ 1,728) × quantity on hand, finished goods', value: 'cu ft', source: 'item sizes + stock movements' },
                    { label: 'Rack = filament grams on hand ÷ grams per spool', value: 'spools', source: 'Settings: spool grams, rack size' },
                    { label: 'Warning above', value: `${(warn * 100).toFixed(0)}%`, source: 'Settings: capacity warning level (warn, never block)' },
                  ]}
                />
              </div>
            );
          })()}

          <h2>Recent activity</h2>
          {data.activity.length === 0 ? (
            <p className="muted">Nothing yet.</p>
          ) : (
            <ul className="activity">
              {data.activity.map((a) => (
                <li key={a.id}>
                  <span className="muted small">{dateTime(a.at)} · {a.actor ?? 'system'}</span>
                  <span>{a.link && /^\/(sales|production|purchasing|returns)\/[0-9a-f-]{36}$/.test(a.link) ? <Link to={a.link}>{a.summary}</Link> : a.summary}</span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  );
}
