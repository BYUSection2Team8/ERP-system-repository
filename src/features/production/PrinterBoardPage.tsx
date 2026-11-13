import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ShowMath } from '../../app/ShowMath';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, rpc, unwrap } from '../../lib/db';
import { dateTime } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { addDays, localToday, pctText } from './productionShared';

// Printer board (wow factor #5): what each P2S is printing, how far along, when it
// finishes, the queue waiting for a printer, and 30-day utilization / scrap.

interface Printer {
  id: string;
  code: string;
  name: string;
  model: string | null;
  is_active: boolean;
  notes: string | null;
}
interface Job {
  id: string;
  mo_no: string;
  status: 'planned' | 'in_progress';
  printer_id: string | null;
  plates: number;
  qty_started: number;
  qty_planned: number;
  started_at: string | null;
  due_date: string | null;
  so_id: string | null;
  item: { name: string; print_minutes: number | null } | null;
  finish?: string | null;
}
interface Stats {
  printer_id: string;
  jobs: number;
  units_started: number;
  units_scrapped: number;
  scrap_rate: number | null;
  busy_hours: number;
  utilization: number | null;
}

async function load() {
  const c = db();
  const today = localToday();
  const [printers, jobs, stats] = await Promise.all([
    c.from('printers').select('*').order('sort_order').then(unwrap<Printer[]>),
    c.from('production_orders').select('id, mo_no, status, printer_id, plates, qty_started, qty_planned, started_at, due_date, so_id, item:items(name, print_minutes)')
      .in('status', ['planned', 'in_progress']).order('created_at').then((r) => unwrap(r) as unknown as Job[]),
    c.rpc('printer_stats', { p_from: addDays(today, -29), p_to: today }).then(unwrap<Stats[]>),
  ]);
  const running = jobs.filter((j) => j.status === 'in_progress');
  const finishes = await Promise.all(running.map((j) => rpc<string>('mo_estimated_finish', { p_mo_id: j.id })));
  running.forEach((j, i) => (j.finish = finishes[i]));
  return { printers, jobs, stats: new Map(stats.map((s) => [s.printer_id, s])) };
}

function remaining(ms: number) {
  if (ms <= 0) return 'done — waiting to be taken off';
  const m = Math.round(ms / 60000);
  return m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min left` : `${m} min left`;
}

export function PrinterBoardPage() {
  const { data, error, loading } = useLiveQuery(load, ['production_orders', 'printers']);
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), 30000);
    return () => window.clearInterval(t);
  }, []);

  return (
    <div>
      <PageHeader
        title="Printer board"
        subtitle="Each print is put on the least busy printer when its components are issued (you can move it on the production order). Progress and finish times use the item's print time and the number of plates."
        actions={<Link className="btn" to="/production">Production orders</Link>}
      />
      {loading && <Loading what="printers" />}
      {error && <ErrorNotice message={error} />}
      {data && (() => {
        const running = data.jobs.filter((j) => j.status === 'in_progress');
        const queued = data.jobs.filter((j) => j.status === 'planned');
        const queueHours = queued.reduce((s, j) => s + (j.plates * Number(j.item?.print_minutes ?? 60)) / 60, 0);
        const busy = data.printers.filter((p) => running.some((j) => j.printer_id === p.id)).length;
        return (
          <>
            <div className="stats">
              <Stat label="Printers busy" value={`${busy} of ${data.printers.filter((p) => p.is_active).length}`} />
              <Stat label="Prints running" value={running.length} />
              <Stat label="Waiting for a printer" value={queued.length} hint={`${queueHours.toFixed(1)} print hours planned`} />
            </div>
            <div className="printer-grid">
              {data.printers.map((p) => {
                const jobs = running.filter((j) => j.printer_id === p.id);
                const st = data.stats.get(p.id);
                return (
                  <div key={p.id} className={`card printer-card ${jobs.length ? 'busy' : 'idle'}`}>
                    <div className="printer-head">
                      <h2 style={{ margin: 0 }}>{p.name}</h2>
                      <span className={`badge ${jobs.length ? 'ok' : ''}`}>{!p.is_active ? 'Out of service' : jobs.length ? 'Printing' : 'Idle'}</span>
                    </div>
                    <div className="muted small">{p.model}</div>
                    {jobs.length === 0 && <p className="muted">No print running.</p>}
                    {jobs.map((j) => {
                      const start = j.started_at ? new Date(j.started_at).getTime() : now;
                      const end = j.finish ? new Date(j.finish).getTime() : now;
                      const pct = Math.min(1, Math.max(0, (now - start) / Math.max(1, end - start)));
                      return (
                        <div key={j.id} className="printer-job">
                          <Link to={`/production/${j.id}`}><strong>{j.mo_no}</strong></Link> · {j.item?.name}
                          <div className="muted small">{j.plates} plate{j.plates === 1 ? '' : 's'} · started {dateTime(j.started_at)}</div>
                          <div className="progress"><span style={{ width: `${Math.round(pct * 100)}%` }} /></div>
                          <div className="small">{Math.round(pct * 100)}% · {remaining(end - now)} · done about {dateTime(j.finish)}</div>
                        </div>
                      );
                    })}
                    {st && (
                      <>
                        <div className="printer-stats small">
                          <span>Last 30 days: <strong>{st.jobs}</strong> jobs</span>
                          <span>Utilization <strong>{pctText(st.utilization)}</strong></span>
                          <span className={Number(st.scrap_rate) >= 0.08 ? 'bad' : ''}>Scrap <strong>{pctText(st.scrap_rate)}</strong></span>
                        </div>
                        <ShowMath
                          rows={[
                            { label: 'Busy hours (start → finish of each print, clipped to the 30 days)', value: Number(st.busy_hours).toLocaleString() },
                            { label: 'Utilization = busy hours ÷ (30 × 24 h)', value: pctText(st.utilization) },
                            { label: `Scrap rate = ${Number(st.units_scrapped)} scrapped ÷ ${Number(st.units_started)} started`, value: pctText(st.scrap_rate) },
                          ]}
                        />
                      </>
                    )}
                  </div>
                );
              })}
            </div>
            {running.some((j) => !j.printer_id) && (
              <p className="notice warn">Some running prints have no printer. Open the production order to assign one.</p>
            )}
            <h2>Waiting for a printer ({queued.length})</h2>
            {queued.length === 0 ? (
              <p className="muted">Nothing planned.</p>
            ) : (
              <div className="table-wrap">
                <table className="table">
                  <thead>
                    <tr><th>Order</th><th>Item</th><th className="num">Plates</th><th className="num">Print hours</th><th>Due</th></tr>
                  </thead>
                  <tbody>
                    {queued.map((j) => (
                      <tr key={j.id}>
                        <td><Link to={`/production/${j.id}`}>{j.mo_no}</Link>{j.so_id && <span className="badge">for an order</span>}</td>
                        <td>{j.item?.name}</td>
                        <td className="num">{j.plates}</td>
                        <td className="num">{((j.plates * Number(j.item?.print_minutes ?? 60)) / 60).toFixed(1)}</td>
                        <td>{j.due_date ?? '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <p className="muted small">Failure rate by printer: <Link to="/reports?tab=failures">Reports → Print failures</Link>.</p>
          </>
        );
      })()}
    </div>
  );
}
