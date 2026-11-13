import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { date, dateTime, money, qty, unitCost } from '../../lib/format';
import type { MoStatus, ProductionOrderRow } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { MoStatusBadge, hoursText } from './productionShared';

type Tab = MoStatus | 'all';
const tabs: { key: Tab; label: string }[] = [
  { key: 'planned', label: 'Planned' },
  { key: 'in_progress', label: 'In progress' },
  { key: 'completed', label: 'Completed' },
  { key: 'cancelled', label: 'Cancelled' },
  { key: 'all', label: 'All' },
];
const statuses: MoStatus[] = ['planned', 'in_progress', 'completed', 'cancelled'];
const LIMIT = 200;

async function load(tab: Tab) {
  const c = db();
  let q = c.from('v_production_orders').select('*');
  if (tab !== 'all') q = q.eq('status', tab);
  const [orders, counts, wip] = await Promise.all([
    q.order('created_at', { ascending: false }).limit(LIMIT).then(unwrap<ProductionOrderRow[]>),
    Promise.all(
      statuses.map((s) =>
        c.from('production_orders').select('id', { count: 'exact', head: true }).eq('status', s).then((r) => {
          if (r.error) throw new Error(r.error.message);
          return [s, r.count ?? 0] as const;
        }),
      ),
    ),
    c.from('v_account_balances').select('balance').eq('code', '1250').then(unwrap<{ balance: number }[]>),
  ]);
  return { orders, counts: new Map<MoStatus, number>(counts), wip: Number(wip[0]?.balance ?? 0) };
}

export function ProductionOrdersPage() {
  const [tab, setTab] = useState<Tab>('in_progress');
  const [search, setSearch] = useState('');
  const navigate = useNavigate();
  const { data, error, loading } = useLiveQuery(() => load(tab), ['production_orders', 'ledger'], [tab]);

  const rows = useMemo(() => {
    if (!data) return [];
    const t = search.trim().toLowerCase();
    if (!t) return data.orders;
    return data.orders.filter((o) => o.mo_no.toLowerCase().includes(t) || o.item_name.toLowerCase().includes(t) || o.sku.toLowerCase().includes(t));
  }, [data, search]);

  return (
    <div>
      <PageHeader
        title="Production orders"
        subtitle="Planned → Issued (components consumed into work in process) → Completed (good units received at rolled-up cost, scrap expensed with a reason)."
        actions={
          <>
            <Link className="btn primary" to="/production/new">New production order</Link>
            <Link className="btn" to="/production/report">Production report</Link>
          </>
        }
      />
      {loading && <Loading what="production orders" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Planned (not issued)" value={data.counts.get('planned') ?? 0} hint="Components not yet consumed" />
            <Stat label="In progress" value={data.counts.get('in_progress') ?? 0} hint="Printing / assembling" />
            <Stat label="Work in process" value={money(data.wip)} hint="Ledger account 1250" />
            <Stat label="Completed" value={data.counts.get('completed') ?? 0} hint={<Link to="/production/report">Metrics by date range</Link>} />
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
            <input className="grow" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search order number or item" aria-label="Search production orders" />
          </div>

          {rows.length === 0 ? (
            <div className="card muted">No production orders here.</div>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Order</th>
                    <th>Item</th>
                    <th className="num">Plates</th>
                    <th className="num">Started</th>
                    <th className="num">Good</th>
                    <th className="num">Scrap</th>
                    <th>Due</th>
                    <th>Started / finished</th>
                    <th className="num">Cycle</th>
                    <th className="num">Unit cost</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((o) => (
                    <tr key={o.id} className="clickable" onClick={() => navigate(`/production/${o.id}`)}>
                      <td className="strong"><Link to={`/production/${o.id}`} onClick={(e) => e.stopPropagation()}>{o.mo_no}</Link></td>
                      <td>{o.item_name}<div className="muted small">{o.sku}</div></td>
                      <td className="num">{o.plates}</td>
                      <td className="num">{o.status === 'planned' ? <span className="muted">{qty(o.qty_planned)}</span> : qty(o.qty_started)}</td>
                      <td className="num">{o.status === 'completed' ? qty(o.qty_good) : '—'}</td>
                      <td className={`num ${Number(o.qty_scrap) > 0 ? 'bad' : ''}`}>{o.status === 'completed' ? qty(o.qty_scrap) : '—'}</td>
                      <td className={o.on_time === false ? 'bad' : ''}>{date(o.due_date)}</td>
                      <td className="small">
                        {o.started_at ? dateTime(o.started_at) : <span className="muted">not started</span>}
                        {o.finished_at && <div>{dateTime(o.finished_at)}</div>}
                      </td>
                      <td className="num">{hoursText(o.cycle_hours)}</td>
                      <td className="num">{o.unit_cost === null ? '—' : unitCost(o.unit_cost)}</td>
                      <td><MoStatusBadge status={o.status} />{o.on_time === false && <span className="badge bad">Late</span>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {data.orders.length === LIMIT && <p className="muted small">Showing the latest {LIMIT}. Use the production report for a date range.</p>}
        </>
      )}
    </div>
  );
}
