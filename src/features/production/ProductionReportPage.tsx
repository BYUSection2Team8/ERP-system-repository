import { useState } from 'react';
import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { date, money, qty, unitCost } from '../../lib/format';
import type { ProductionMetrics, ProductionOrderRow } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { ShowMath } from '../../app/ShowMath';
import { MoStatusBadge, addDays, hoursText, localToday, pctText } from './productionShared';

interface ScrapRow {
  reason_code: string;
  description: string | null;
  orders: number;
  qty_scrap: number;
  scrap_cost: number;
}

const LIMIT = 500;

async function load(from: string, to: string) {
  const c = db();
  const [metrics, scrap, orders] = await Promise.all([
    c.rpc('production_metrics', { p_from: from, p_to: to }).then((r) => unwrap<ProductionMetrics[]>(r)[0]),
    c.rpc('production_scrap_by_reason', { p_from: from, p_to: to }).then((r) => unwrap<ScrapRow[]>(r)),
    c.from('v_production_orders').select('*').gte('report_date', from).lte('report_date', to)
      .order('report_date', { ascending: false }).limit(LIMIT).then(unwrap<ProductionOrderRow[]>),
  ]);
  return { metrics, scrap, orders };
}

const presets: { label: string; days: number }[] = [
  { label: 'Last 7 days', days: 7 },
  { label: 'Last 30 days', days: 30 },
  { label: 'Last 90 days', days: 90 },
  { label: 'Last 6 months', days: 183 },
];

export function ProductionReportPage() {
  const today = localToday();
  const [from, setFrom] = useState(addDays(today, -29));
  const [to, setTo] = useState(today);
  const { data, error, loading } = useLiveQuery(() => load(from, to), ['production_orders'], [from, to]);
  const m = data?.metrics;

  return (
    <div>
      <PageHeader
        title="Production report"
        subtitle="Production orders in a date range (by finish date, or start / created date if not finished). Every metric is computed from the stored orders."
        actions={<Link className="btn" to="/production">Production orders</Link>}
      />
      <div className="toolbar">
        <label>
          From
          <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} />
        </label>
        <label>
          To
          <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} />
        </label>
        <div className="choice-row" style={{ alignSelf: 'flex-end' }}>
          {presets.map((p) => (
            <button key={p.label} type="button" className="btn" onClick={() => { setFrom(addDays(today, -(p.days - 1))); setTo(today); }}>
              {p.label}
            </button>
          ))}
        </div>
      </div>

      {loading && <Loading what="production report" />}
      {error && <ErrorNotice message={error} />}
      {data && m && (
        <>
          <div className="stats">
            <Stat
              label="First-pass yield"
              value={pctText(m.first_pass_yield)}
              hint={`Completed orders with no scrap (of ${m.orders_completed})`}
              tone={m.first_pass_yield !== null && Number(m.first_pass_yield) < 0.9 ? 'warn' : undefined}
            />
            <Stat
              label="Scrap rate"
              value={pctText(m.scrap_rate)}
              hint={`${qty(m.qty_scrap)} of ${qty(m.qty_started)} units started · ${money(m.scrap_cost)} expensed`}
              tone={m.scrap_rate !== null && Number(m.scrap_rate) > 0.05 ? 'warn' : undefined}
            />
            <Stat label="Average cycle time" value={hoursText(m.avg_cycle_hours)} hint="Issue (start) to completion (finish)" />
            <Stat
              label="On-time completion"
              value={pctText(m.on_time_rate)}
              hint={`${m.orders_on_time} of ${m.orders_with_due} orders with a due date`}
              tone={m.on_time_rate !== null && Number(m.on_time_rate) < 0.85 ? 'warn' : undefined}
            />
            <Stat label="Unit yield" value={pctText(m.unit_yield)} hint={`${qty(m.qty_good)} good units`} />
            <Stat label="Production cost" value={money(m.production_cost)} hint={`${m.orders_completed} completed · ${m.orders_open} still open`} />
          </div>

          <ShowMath
            rows={[
              { label: `First-pass yield = completed orders with no scrap ÷ completed orders = ${Math.round(Number(m.first_pass_yield ?? 0) * m.orders_completed)} ÷ ${m.orders_completed}`, value: pctText(m.first_pass_yield), source: 'production orders finished in the range' },
              { label: `Scrap rate = units scrapped ÷ units started = ${qty(m.qty_scrap)} ÷ ${qty(m.qty_started)}`, value: pctText(m.scrap_rate), source: 'good + scrapped recorded at completion' },
              { label: `Unit yield = good units ÷ units started = ${qty(m.qty_good)} ÷ ${qty(m.qty_started)}`, value: pctText(m.unit_yield) },
              { label: 'Average cycle time = average of (finish time − start time)', value: hoursText(m.avg_cycle_hours), source: 'start = components issued' },
              { label: `On-time = finished on or before the due date = ${m.orders_on_time} ÷ ${m.orders_with_due}`, value: pctText(m.on_time_rate) },
              { label: 'Scrap cost = scrapped units × rolled-up unit cost', value: money(m.scrap_cost), source: 'ledger 5300 Production scrap' },
            ]}
          />

          <h2>Scrap by reason</h2>
          {data.scrap.length === 0 ? (
            <p className="muted">No scrap in this range.</p>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Reason</th>
                    <th className="num">Orders</th>
                    <th className="num">Units scrapped</th>
                    <th className="num">Cost</th>
                  </tr>
                </thead>
                <tbody>
                  {data.scrap.map((s) => (
                    <tr key={s.reason_code}>
                      <td>{s.description ?? s.reason_code}</td>
                      <td className="num">{s.orders}</td>
                      <td className="num">{qty(s.qty_scrap)}</td>
                      <td className="num">{money(s.scrap_cost)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <h2>Orders ({data.orders.length}{data.orders.length === LIMIT ? '+' : ''})</h2>
          {data.orders.length === 0 ? (
            <p className="muted">No production orders in this range.</p>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Order</th>
                    <th>Date</th>
                    <th>Item</th>
                    <th className="num">Started</th>
                    <th className="num">Good</th>
                    <th className="num">Scrap</th>
                    <th>Reason</th>
                    <th className="num">Cycle</th>
                    <th>Due</th>
                    <th className="num">Unit cost</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  {data.orders.map((o) => (
                    <tr key={o.id}>
                      <td className="strong"><Link to={`/production/${o.id}`}>{o.mo_no}</Link></td>
                      <td>{date(o.report_date)}</td>
                      <td>{o.item_name}</td>
                      <td className="num">{qty(o.qty_started)}</td>
                      <td className="num">{o.status === 'completed' ? qty(o.qty_good) : '—'}</td>
                      <td className={`num ${Number(o.qty_scrap) > 0 ? 'bad' : ''}`}>{o.status === 'completed' ? qty(o.qty_scrap) : '—'}</td>
                      <td className="small">{o.scrap_reason ? data.scrap.find((s) => s.reason_code === o.scrap_reason)?.description ?? o.scrap_reason : ''}</td>
                      <td className="num">{hoursText(o.cycle_hours)}</td>
                      <td className={o.on_time === false ? 'bad' : ''}>{date(o.due_date)}</td>
                      <td className="num">{o.unit_cost === null ? '—' : unitCost(o.unit_cost)}</td>
                      <td><MoStatusBadge status={o.status} />{o.on_time === false && <span className="badge bad">Late</span>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
