import { useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import { date, money, qty, unitCost } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { addDays, localToday } from '../production/productionShared';
import { useCreatePos } from './purchasingShared';
import { loadReorderPlan, n, reorderTables, type ReorderRow } from './reorderShared';

type Filter = 'below' | 'purchased' | 'made' | 'all';

export function ReorderPlanningPage() {
  const { data, error, loading } = useLiveQuery(loadReorderPlan, reorderTables);
  const [filter, setFilter] = useState<Filter>('below');
  const [result, setResult] = useState<{ ok: boolean; text: ReactNode } | null>(null);
  const [planning, setPlanning] = useState<string | null>(null);
  const po = useCreatePos();
  const today = localToday();

  if (loading) return <Loading what="reorder plan" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const s = data.settings;

  const active = data.rows.filter((r) => Number(r.avg_daily) > 0);
  const below = active.filter((r) => r.below_reorder_point);
  const rows = (filter === 'below' ? below : filter === 'purchased' ? active.filter((r) => r.replenish_by === 'purchase') : filter === 'made' ? active.filter((r) => r.replenish_by === 'production') : data.rows)
    .slice()
    .sort((a, b) => Number(b.below_reorder_point) - Number(a.below_reorder_point) || (a.order_by_date ?? '9').localeCompare(b.order_by_date ?? '9'));

  const bySupplier = new Map<string, ReorderRow[]>();
  for (const r of below) if (r.replenish_by === 'purchase' && r.supplier_id) bySupplier.set(r.supplier_id, [...(bySupplier.get(r.supplier_id) ?? []), r]);
  const makeBelow = below.filter((r) => r.replenish_by === 'production');

  async function orderFrom(supplierId: string) {
    const lines = (bySupplier.get(supplierId) ?? []).map((r) => ({ item_id: r.item_id, qty: Number(r.suggested_units) }));
    const id = await po.create(supplierId, lines, 'reorder', 'Reorder point reached');
    if (id) setResult({ ok: true, text: <>Purchase order sent. <Link to={`/purchasing/${id}`}>Open it</Link>. The items' inventory position now includes it.</> });
  }

  async function plan(r: ReorderRow) {
    setPlanning(r.item_id);
    setResult(null);
    try {
      const id = await rpc<string>('create_production_order', {
        p_item: r.item_id,
        p_qty: Number(r.suggested_qty),
        p_due_date: addDays(today, r.lead_days),
        p_notes: 'Reorder point reached (economic batch)',
      });
      setResult({ ok: true, text: <>Production order planned. <Link to={`/production/${id}`}>Open it</Link>.</> });
    } catch (e) {
      setResult({ ok: false, text: errorMessage(e) });
    } finally {
      setPlanning(null);
    }
  }

  return (
    <div>
      <PageHeader
        title="Reorder planning"
        subtitle={`Continuous review from the last ${s.get('demand_history_days')} days of history: when the inventory position reaches the reorder point, order the EOQ.`}
        actions={
          <>
            <Link className="btn" to="/purchasing/review">Periodic review</Link>
            <Link className="btn" to="/settings">Change ordering settings</Link>
          </>
        }
      />

      <div className="stats">
        <Stat label="At or below reorder point" value={below.length} tone={below.length ? 'warn' : undefined} hint={`${bySupplier.size} supplier(s), ${makeBelow.length} made item(s)`} />
        <Stat label="Ordering cost per PO (S)" value={money(s.get('ordering_cost'))} hint={`Setup per production batch ${money(s.get('production_setup_cost'))}`} />
        <Stat label="Carrying rate (H = cost × rate)" value={`${((s.get('carrying_rate_annual') ?? 0) * 100).toFixed(0)}% / yr`} hint={`Seasonal items ${((s.get('carrying_rate_seasonal') ?? 0) * 100).toFixed(0)}%`} />
        <Stat label="Service level z" value={n(s.get('service_level_z'))} hint="1.65 ≈ 95% in stock during lead time" />
      </div>

      <div className="card muted small">
        <strong>The math.</strong> d̄ = average daily usage (sales for products, production issues for components; zero days included; seasonal items use in-season days),
        σ = its standard deviation, L = lead time in days. <span className="math">Reorder point = d̄·L + z·σ·√L</span>.{' '}
        <span className="math">EOQ = √(2·D·S ÷ H)</span> with D = 365·d̄ and H = unit cost × carrying rate.{' '}
        Position = on hand + on order − committed. Order-by = the day the position is expected to reach the reorder point.
      </div>

      {result && <div className={`notice ${result.ok ? 'ok' : 'error'} spaced`}>{result.text}</div>}
      {po.error && <div className="notice error spaced">{po.error}</div>}

      {(bySupplier.size > 0 || makeBelow.length > 0) && (
        <>
          <h2>Suggested now</h2>
          <div className="supplier-cards">
            {[...bySupplier.entries()].map(([sid, list]) => (
              <div className="card" key={sid}>
                <div className="page-header" style={{ marginBottom: '0.5rem' }}>
                  <strong>{list[0].supplier_name}</strong>
                  <button className="btn primary" disabled={po.busy !== null} onClick={() => orderFrom(sid)}>
                    {po.busy === sid ? 'Sending…' : 'Create & send PO'}
                  </button>
                </div>
                <table className="table">
                  <tbody>
                    {list.map((r) => (
                      <tr key={r.item_id}>
                        <td>{r.name}</td>
                        <td className="num">{n(r.suggested_units, 0)} {r.purchase_uom}</td>
                        <td className="num">{money(Number(r.suggested_units) * Number(r.purchase_unit_cost ?? 0))}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ))}
            {makeBelow.length > 0 && (
              <div className="card">
                <strong>Make in-house</strong>
                <table className="table">
                  <tbody>
                    {makeBelow.map((r) => (
                      <tr key={r.item_id}>
                        <td>{r.name}</td>
                        <td className="num">{n(r.suggested_qty, 0)}</td>
                        <td>
                          <button className="btn link" disabled={planning !== null} onClick={() => plan(r)}>
                            {planning === r.item_id ? 'Planning…' : 'Plan batch'}
                          </button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </>
      )}

      <div className="toolbar spaced">
        <div className="tabs">
          {([['below', `Below reorder point (${below.length})`], ['purchased', 'Purchased'], ['made', 'Made in-house'], ['all', 'All items']] as [Filter, string][]).map(([k, label]) => (
            <button key={k} className={filter === k ? 'active' : ''} onClick={() => setFilter(k)}>{label}</button>
          ))}
        </div>
      </div>

      {rows.length === 0 ? (
        <div className="card muted">Nothing here: every inventory position is above its reorder point.</div>
      ) : (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Item</th>
                <th className="num">d̄ / day</th>
                <th className="num">σ</th>
                <th className="num">L</th>
                <th className="num">Reorder point</th>
                <th className="num">EOQ</th>
                <th className="num">On hand</th>
                <th className="num">On order</th>
                <th className="num">Committed</th>
                <th className="num">Position</th>
                <th className="num">Days left</th>
                <th>Order by</th>
                <th className="num">Suggested</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const late = r.order_by_date !== null && r.order_by_date <= today;
                return (
                  <tr key={r.item_id} className={r.below_reorder_point ? 'row-alert' : ''}>
                    <td>
                      <Link to={`/inventory/item/${r.item_id}`}>{r.name}</Link>
                      <div className="muted small">{r.replenish_by === 'purchase' ? r.supplier_name ?? 'no supplier' : 'made in-house'} · {r.days_observed} days of history</div>
                    </td>
                    <td className="num">{n(r.avg_daily, 2)}</td>
                    <td className="num">{n(r.sd_daily, 2)}</td>
                    <td className="num">{r.lead_days} d</td>
                    <td className="num">
                      <strong>{qty(r.reorder_point, r.uom)}</strong>
                      <div className="math">
                        {r.reorder_point_manual !== null ? 'manual override' : `${n(r.avg_daily)}×${r.lead_days} + ${n(r.z)}×${n(r.sd_daily)}×√${r.lead_days}`}
                      </div>
                    </td>
                    <td className="num">
                      {r.eoq === null ? '—' : <strong>{qty(r.eoq, r.uom)}</strong>}
                      {r.eoq !== null && (
                        <div className="math">
                          √(2×{n(r.annual_demand, 0)}×{money(r.order_cost)}÷{unitCost(r.holding_cost_unit)})
                          {Number(r.pack) !== 1 && <> = {n(r.eoq_units, 0)} {r.purchase_uom}</>}
                        </div>
                      )}
                    </td>
                    <td className="num">{qty(r.on_hand, r.uom)}</td>
                    <td className="num">{qty(r.on_order, r.uom)}</td>
                    <td className="num">{qty(r.committed, r.uom)}</td>
                    <td className={`num strong ${r.below_reorder_point ? 'bad' : ''}`}>{qty(r.position, r.uom)}</td>
                    <td className="num">{r.days_of_supply === null ? '—' : n(r.days_of_supply, 0)}</td>
                    <td className={late ? 'bad strong' : ''}>{date(r.order_by_date)}</td>
                    <td className="num">
                      {r.suggested_units === null ? <span className="muted">—</span> : <strong>{n(r.suggested_units, 0)} {r.replenish_by === 'purchase' ? r.purchase_uom : r.uom}</strong>}
                    </td>
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
