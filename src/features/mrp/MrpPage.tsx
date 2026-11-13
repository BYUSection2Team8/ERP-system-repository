import { Fragment, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { date, money, qty } from '../../lib/format';
import type { Item, MrpComponentRow, MrpParentRow, Supplier } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { localToday } from '../production/productionShared';

const WEEKS = 4;

async function load() {
  const c = db();
  const [parents, comps, items, suppliers] = await Promise.all([
    c.rpc('mrp_parent_plan', { p_weeks: WEEKS }).then((r) => unwrap<MrpParentRow[]>(r)),
    c.rpc('mrp_component_plan', { p_weeks: WEEKS }).then((r) => unwrap<MrpComponentRow[]>(r)),
    c.from('items').select('*').then(unwrap<Item[]>),
    c.from('suppliers').select('*').then(unwrap<Supplier[]>),
  ]);
  return {
    parents: group(parents),
    comps: group(comps),
    items: new Map(items.map((i) => [i.id, i])),
    suppliers: new Map(suppliers.map((s) => [s.id, s])),
  };
}

function group<T extends { item_id: string; week_no: number }>(rows: T[]): Map<string, T[]> {
  const m = new Map<string, T[]>();
  for (const r of rows) m.set(r.item_id, [...(m.get(r.item_id) ?? []), r]);
  for (const v of m.values()) v.sort((a, b) => a.week_no - b.week_no);
  return m;
}

function weekLabel(isoDate: string, i: number): string {
  return `${i === 0 ? 'This week' : `Week ${i + 1}`} · ${date(isoDate).replace(/, \d{4}$/, '')}`;
}

export function MrpPage() {
  const { data, error, loading } = useLiveQuery(load, [
    'sales_orders',
    'sales_order_lines',
    'production_orders',
    'purchase_orders',
    'purchase_order_lines',
    'inventory_txn',
  ]);
  const [busy, setBusy] = useState<string | null>(null);
  const [result, setResult] = useState<{ ok: boolean; text: ReactNode } | null>(null);
  const today = localToday();

  if (loading) return <Loading what="material requirements" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;

  const weeks = [...data.parents.values(), ...data.comps.values()][0]?.map((r) => r.week_start) ?? [];
  const parentIds = [...data.parents.keys()].sort((a, b) => (data.items.get(a)?.name ?? '').localeCompare(data.items.get(b)?.name ?? ''));
  const compIds = [...data.comps.keys()].sort((a, b) => (data.items.get(a)?.name ?? '').localeCompare(data.items.get(b)?.name ?? ''));

  // Suggested purchase orders: every planned order, grouped by preferred supplier.
  const bySupplier = new Map<string, MrpComponentRow[]>();
  for (const rows of data.comps.values())
    for (const r of rows)
      if (Number(r.planned_order_units) > 0 && r.supplier_id) bySupplier.set(r.supplier_id, [...(bySupplier.get(r.supplier_id) ?? []), r]);
  const plannedMos = [...data.parents.values()].flat().filter((r) => r.planned_plates > 0);
  const lateOrders = [...bySupplier.values()].flat().filter((r) => r.order_by_date && r.order_by_date < today).length;

  async function createPo(supplierId: string) {
    const rows = bySupplier.get(supplierId) ?? [];
    setBusy(supplierId);
    setResult(null);
    try {
      const id = await rpc<string>('create_purchase_order', {
        p: {
          supplier_id: supplierId,
          source: 'mrp',
          notes: 'Created from MRP',
          lines: rows.map((r) => ({ item_id: r.item_id, qty: Number(r.planned_order_units), need_date: r.need_date })),
        },
      });
      setResult({ ok: true, text: <>Purchase order sent to {data!.suppliers.get(supplierId)?.name}. <Link to={`/purchasing/${id}`}>Open it</Link>. MRP now counts it as a scheduled receipt.</> });
    } catch (e) {
      setResult({ ok: false, text: errorMessage(e) });
    } finally {
      setBusy(null);
    }
  }

  async function createMo(r: MrpParentRow) {
    const key = `${r.item_id}|${r.week_no}`;
    setBusy(key);
    setResult(null);
    try {
      const id = await rpc<string>('create_production_order', {
        p_item: r.item_id,
        p_qty: Number(r.planned_qty),
        p_due_date: r.need_date,
        p_notes: 'Planned by MRP',
      });
      setResult({ ok: true, text: <>Production order planned. <Link to={`/production/${id}`}>Open it</Link>. Its components stay on the requirements list until it is issued.</> });
    } catch (e) {
      setResult({ ok: false, text: errorMessage(e) });
    } finally {
      setBusy(null);
    }
  }

  return (
    <div>
      <PageHeader
        title="Material requirements planning"
        subtitle="Open sales orders × bill of material, netted against stock, open production orders and open purchase orders, over the next 4 weeks."
        actions={
          <>
            <Link className="btn" to="/production">Production orders</Link>
            <Link className="btn" to="/purchasing">Purchase orders</Link>
          </>
        }
      />

      <div className="stats">
        <Stat label="Products with open demand" value={parentIds.length} hint="Items we make, on placed sales orders" />
        <Stat label="Production to plan" value={plannedMos.length} hint={plannedMos.length ? 'Weeks needing a new production order' : 'Demand is covered'} tone={plannedMos.length ? 'warn' : undefined} />
        <Stat label="Components to order" value={[...bySupplier.values()].flat().length} hint={`${bySupplier.size} supplier${bySupplier.size === 1 ? '' : 's'}`} tone={bySupplier.size ? 'warn' : undefined} />
        <Stat label="Order-by date already passed" value={lateOrders} tone={lateOrders ? 'bad' : undefined} hint={lateOrders ? 'Order today and expedite' : 'Nothing late'} />
      </div>

      <div className="card muted small">
        <strong>How MRP works here.</strong> (1) Gross demand = open quantity on placed sales orders, in the week it is needed (overdue goes in this week).
        (2) Net = demand − finished stock − open production orders; planned production is rounded up to whole plates, started by need date − production lead time.
        (3) Each planned plate × its bill of material, plus components of planned (not yet issued) production orders = gross component requirements.
        (4) Net component requirement = requirements − on hand − open purchase orders arriving by that week; the planned order is rounded up to whole purchase units
        (spools of 985 g, each) and must be ordered by the need date − supplier lead time.
      </div>

      {result && <div className={`notice ${result.ok ? 'ok' : 'error'} spaced`}>{result.text}</div>}

      <h2>Suggested purchase orders</h2>
      {bySupplier.size === 0 ? (
        <p className="muted">Nothing to order: on-hand stock and open purchase orders cover every component requirement in the next 4 weeks.</p>
      ) : (
        <div className="supplier-cards">
          {[...bySupplier.entries()].map(([sid, rows]) => {
            const sup = data.suppliers.get(sid);
            const total = rows.reduce((s, r) => s + Number(r.planned_order_units) * Number(r.unit_cost ?? 0), 0);
            return (
              <div className="card" key={sid}>
                <div className="page-header" style={{ marginBottom: '0.5rem' }}>
                  <div>
                    <strong>{sup?.name ?? 'Supplier'}</strong>
                    <div className="muted small">Lead time {sup?.quoted_lead_days ?? '?'} days · {sup?.payment_terms}</div>
                  </div>
                  <button className="btn primary" disabled={busy !== null} onClick={() => createPo(sid)}>
                    {busy === sid ? 'Sending…' : 'Create & send PO'}
                  </button>
                </div>
                <table className="table">
                  <thead>
                    <tr>
                      <th>Component</th>
                      <th className="num">Order</th>
                      <th>Need by</th>
                      <th>Order by</th>
                      <th className="num">Est. cost</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((r) => {
                      const late = r.order_by_date !== null && r.order_by_date < today;
                      return (
                        <tr key={`${r.item_id}-${r.week_no}`}>
                          <td>{data.items.get(r.item_id)?.name}</td>
                          <td className="num">{qty(r.planned_order_units)} {r.purchase_uom}{Number(r.stock_per_purchase_unit) !== 1 && <div className="muted small">{qty(r.planned_order_qty, 'g')}</div>}</td>
                          <td>{date(r.need_date)}</td>
                          <td className={late ? 'bad strong' : ''}>{date(r.order_by_date)}{late && <div className="small">late: order now</div>}</td>
                          <td className="num">{money(Number(r.planned_order_units) * Number(r.unit_cost ?? 0))}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                  <tfoot>
                    <tr>
                      <td colSpan={4}>Estimated total (price list)</td>
                      <td className="num">{money(total)}</td>
                    </tr>
                  </tfoot>
                </table>
              </div>
            );
          })}
        </div>
      )}

      <h2>Level 0 — products we make</h2>
      {parentIds.length === 0 ? (
        <p className="muted">No placed sales orders for made items in the next 4 weeks.</p>
      ) : (
        <div className="table-wrap">
          <table className="table mrp">
            <thead>
              <tr>
                <th>Item</th>
                <th></th>
                {weeks.map((w, i) => <th key={w} className="num">{weekLabel(w, i)}</th>)}
              </tr>
            </thead>
            <tbody>
              {parentIds.map((pid) => {
                const rows = data.parents.get(pid)!;
                const item = data.items.get(pid);
                return (
                  <Fragment key={pid}>
                    <tr className="mrp-first">
                      <td rowSpan={4} className="mrp-item">
                        <Link to={`/inventory/item/${pid}`}>{item?.name}</Link>
                        <div className="muted small">On hand {qty(rows[0].on_hand)} · {item?.units_per_plate}/plate · lead {rows[0].lead_days} d</div>
                      </td>
                      <td className="muted small">Gross demand</td>
                      {rows.map((r) => <td key={r.week_no} className="num">{zero(r.gross_demand)}</td>)}
                    </tr>
                    <tr>
                      <td className="muted small">Open production</td>
                      {rows.map((r) => <td key={r.week_no} className="num">{zero(r.scheduled_output)}</td>)}
                    </tr>
                    <tr>
                      <td className="muted small">Projected balance</td>
                      {rows.map((r) => <td key={r.week_no} className="num">{qty(r.projected_balance)}</td>)}
                    </tr>
                    <tr>
                      <td className="muted small strong">Planned production</td>
                      {rows.map((r) => (
                        <td key={r.week_no} className="num">
                          {r.planned_plates > 0 ? (
                            <>
                              <strong>{qty(r.planned_qty)}</strong> <span className="muted small">({r.planned_plates} pl.)</span>
                              <div className={`small ${r.start_by && r.start_by < today ? 'bad' : 'muted'}`}>start {date(r.start_by).replace(/, \d{4}$/, '')}</div>
                              <button className="btn link small" disabled={busy !== null} onClick={() => createMo(r)}>
                                {busy === `${r.item_id}|${r.week_no}` ? 'Planning…' : 'Plan it'}
                              </button>
                            </>
                          ) : (
                            <span className="muted">—</span>
                          )}
                        </td>
                      ))}
                    </tr>
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <h2>Level 1 — components (filament and parts)</h2>
      {compIds.length === 0 ? (
        <p className="muted">No component requirements in the next 4 weeks.</p>
      ) : (
        <div className="table-wrap">
          <table className="table mrp">
            <thead>
              <tr>
                <th>Component</th>
                <th></th>
                {weeks.map((w, i) => <th key={w} className="num">{weekLabel(w, i)}</th>)}
              </tr>
            </thead>
            <tbody>
              {compIds.map((cid) => {
                const rows = data.comps.get(cid)!;
                const item = data.items.get(cid);
                const uom = item?.uom ?? 'ea';
                const sup = rows[0].supplier_id ? data.suppliers.get(rows[0].supplier_id) : undefined;
                return (
                  <Fragment key={cid}>
                    <tr className="mrp-first">
                      <td rowSpan={5} className="mrp-item">
                        <Link to={`/inventory/item/${cid}`}>{item?.name}</Link>
                        <div className="muted small">
                          On hand {qty(rows[0].on_hand, uom)} · {sup?.name ?? 'no supplier'} · lead {rows[0].lead_days} d
                        </div>
                      </td>
                      <td className="muted small">Gross requirement</td>
                      {rows.map((r) => <td key={r.week_no} className="num">{zero(r.gross_requirement, uom)}</td>)}
                    </tr>
                    <tr>
                      <td className="muted small">Scheduled receipts</td>
                      {rows.map((r) => <td key={r.week_no} className="num">{zero(r.scheduled_receipts, uom)}</td>)}
                    </tr>
                    <tr>
                      <td className="muted small">Projected on hand</td>
                      {rows.map((r) => <td key={r.week_no} className="num">{qty(r.projected_balance, uom)}</td>)}
                    </tr>
                    <tr>
                      <td className="muted small">Net requirement</td>
                      {rows.map((r) => <td key={r.week_no} className={`num ${Number(r.net_requirement) > 0 ? 'bad' : ''}`}>{zero(r.net_requirement, uom)}</td>)}
                    </tr>
                    <tr>
                      <td className="muted small strong">Planned order</td>
                      {rows.map((r) => (
                        <td key={r.week_no} className="num">
                          {Number(r.planned_order_units) > 0 ? (
                            <>
                              <strong>{qty(r.planned_order_units)} {r.purchase_uom}</strong>
                              <div className={`small ${r.order_by_date && r.order_by_date < today ? 'bad strong' : 'muted'}`}>order by {date(r.order_by_date).replace(/, \d{4}$/, '')}</div>
                            </>
                          ) : (
                            <span className="muted">—</span>
                          )}
                        </td>
                      ))}
                    </tr>
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function zero(v: number | string, uom: 'ea' | 'g' = 'ea') {
  return Number(v) === 0 ? <span className="muted">·</span> : qty(v, uom);
}
