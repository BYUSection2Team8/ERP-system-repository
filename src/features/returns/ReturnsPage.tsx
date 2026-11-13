import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { dateTime, money, qty } from '../../lib/format';
import type { SaleReturn } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';

interface Row extends SaleReturn {
  so: { order_no: string } | null;
  customer: { name: string } | null;
}

const LIMIT = 200;

async function load() {
  const c = db();
  const since = new Date(Date.now() - 30 * 86400000).toISOString();
  const [rows, recent, qa] = await Promise.all([
    c.from('returns').select('*, so:sales_orders!returns_so_id_fkey(order_no), customer:customers(name)')
      .order('returned_at', { ascending: false }).limit(LIMIT).then((r) => unwrap(r) as unknown as Row[]),
    c.from('returns').select('merchandise_credit, restocking_fee, return_type').gte('returned_at', since)
      .then(unwrap<Pick<SaleReturn, 'merchandise_credit' | 'restocking_fee' | 'return_type'>[]>),
    c.from('locations').select('id').eq('code', 'QA_HOLD').maybeSingle().then(unwrap<{ id: string } | null>)
      .then((loc) => (loc ? c.from('v_availability').select('qty_on_hand').eq('location_id', loc.id).then(unwrap<{ qty_on_hand: number }[]>) : Promise.resolve([] as { qty_on_hand: number }[]))),
  ]);
  return { rows, recent, qaUnits: qa.reduce((s, x) => s + Number(x.qty_on_hand), 0) };
}

export function ReturnsPage() {
  const { data, error, loading } = useLiveQuery(load, ['returns', 'return_lines', 'inventory_txn']);
  const [search, setSearch] = useState('');
  const navigate = useNavigate();

  const rows = useMemo(() => {
    if (!data) return [];
    const t = search.trim().toLowerCase();
    if (!t) return data.rows;
    return data.rows.filter((r) => r.return_no.toLowerCase().includes(t) || (r.so?.order_no ?? '').toLowerCase().includes(t) || (r.customer?.name ?? '').toLowerCase().includes(t));
  }, [data, search]);

  return (
    <div>
      <PageHeader
        title="Returns & exchanges"
        subtitle="30-day return policy. Quality failures go to QA Hold with a full refund; other returns go back to stock; a changed-mind refund of a made-to-order item pays a restocking fee. Revenue, tax and COGS are reversed in the ledger."
        actions={<Link className="btn primary" to="/returns/new">New return or exchange</Link>}
      />
      {loading && <Loading what="returns" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Returns, last 30 days" value={data.recent.length} hint={`${data.recent.filter((r) => r.return_type === 'exchange').length} exchanges`} />
            <Stat label="Merchandise credited (30 days)" value={money(data.recent.reduce((s, r) => s + Number(r.merchandise_credit), 0))} />
            <Stat label="Restocking fees (30 days)" value={money(data.recent.reduce((s, r) => s + Number(r.restocking_fee), 0))} />
            <Stat
              label="Units in QA Hold"
              value={qty(data.qaUnits)}
              hint={<Link to="/inventory">Inspect: transfer back or scrap</Link>}
              tone={data.qaUnits > 0 ? 'warn' : undefined}
            />
          </div>
          <div className="toolbar">
            <input className="grow" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search return, order or customer" aria-label="Search returns" />
          </div>
          {rows.length === 0 ? (
            <div className="card muted">No returns yet.</div>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Return</th>
                    <th>Date</th>
                    <th>Order</th>
                    <th>Customer</th>
                    <th>Type</th>
                    <th className="num">Credit</th>
                    <th className="num">Restocking fee</th>
                    <th className="num">Refund</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.id} className="clickable" onClick={() => navigate(`/returns/${r.id}`)}>
                      <td className="strong"><Link to={`/returns/${r.id}`} onClick={(e) => e.stopPropagation()}>{r.return_no}</Link></td>
                      <td>{dateTime(r.returned_at)}</td>
                      <td><Link to={`/sales/${r.so_id}`} onClick={(e) => e.stopPropagation()}>{r.so?.order_no}</Link></td>
                      <td>{r.customer?.name ?? <span className="muted">Walk-in</span>}</td>
                      <td>{r.return_type === 'exchange' ? <span className="badge warn status">Exchange</span> : <span className="badge status">Refund</span>}</td>
                      <td className="num">{money(Number(r.merchandise_credit) + Number(r.tax_credit))}</td>
                      <td className="num">{Number(r.restocking_fee) > 0 ? money(r.restocking_fee) : '—'}</td>
                      <td className="num">{money(r.refund_amount)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {data.rows.length === LIMIT && <p className="muted small">Showing the latest {LIMIT}.</p>}
        </>
      )}
    </div>
  );
}
