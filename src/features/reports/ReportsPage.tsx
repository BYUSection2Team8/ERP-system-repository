import { useState, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat, shortLocation } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { date, money, qty } from '../../lib/format';
import type { Availability, Item, Location } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { addDays, localToday, pctText } from '../production/productionShared';
import { loadReorderPlan, n, reorderTables, type ReorderRow } from '../purchasing/reorderShared';
import { BarChart, DateRange, shortDate } from './reportsShared';

// Manager reports (rubric capability 10). Every figure comes from a database
// function or view over stored transactions, and reloads live.

const tabs = [
  { key: 'sales', label: 'Sales by day / week' },
  { key: 'top', label: 'Top sellers' },
  { key: 'low', label: 'Low stock' },
  { key: 'location', label: 'Inventory by location' },
  { key: 'suppliers', label: 'Supplier performance' },
] as const;
type TabKey = (typeof tabs)[number]['key'];

export function ReportsPage() {
  const [params, setParams] = useSearchParams();
  const tab = (tabs.find((t) => t.key === params.get('tab'))?.key ?? 'sales') as TabKey;
  const today = localToday();
  const [from, setFrom] = useState(addDays(today, -29));
  const [to, setTo] = useState(today);
  const range = (
    <DateRange from={from} to={to} today={today} onChange={(f, t) => { setFrom(f); setTo(t); }} />
  );

  return (
    <div>
      <PageHeader
        title="Reports"
        subtitle="Manager reports computed from the stored orders, stock movements, purchase orders and ledger. They refresh by themselves when anyone posts a change."
        actions={
          <>
            <Link className="btn" to="/production/report">Production report</Link>
            <Link className="btn" to="/finance/pl">Profit & loss</Link>
          </>
        }
      />
      <div className="tabs no-print">
        {tabs.map((t) => (
          <button key={t.key} type="button" className={t.key === tab ? 'active' : ''} onClick={() => setParams({ tab: t.key }, { replace: true })}>
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'sales' && <SalesReport from={from} to={to} range={range} />}
      {tab === 'top' && <TopSellersReport from={from} to={to} range={range} />}
      {tab === 'low' && <LowStockReport />}
      {tab === 'location' && <StockByLocationReport />}
      {tab === 'suppliers' && <SupplierPerformanceReport />}
    </div>
  );
}

// ---------------------------------------------------------------------------
interface PeriodRow {
  period_start: string;
  orders: number;
  units: number;
  gross_sales: number;
  discounts: number;
  returns: number;
  net_sales: number;
  cogs: number;
  gross_profit: number;
}

function SalesReport({ from, to, range }: { from: string; to: string; range: ReactNode }) {
  const [grain, setGrain] = useState<'day' | 'week'>('day');
  const { data, error, loading } = useLiveQuery(
    async () => unwrap<PeriodRow[]>(await db().rpc('sales_by_period', { p_from: from, p_to: to, p_grain: grain })),
    ['ledger', 'sales_orders'],
    [from, to, grain],
  );
  const sum = (k: keyof PeriodRow) => (data ?? []).reduce((s, r) => s + Number(r[k]), 0);
  const net = sum('net_sales');
  const orders = sum('orders');
  const label = (r: PeriodRow) => (grain === 'week' ? `Week of ${shortDate(r.period_start)}` : date(r.period_start));

  return (
    <>
      {range}
      <div className="choice-row spaced">
        <label className="check"><input type="radio" checked={grain === 'day'} onChange={() => setGrain('day')} /> By day</label>
        <label className="check"><input type="radio" checked={grain === 'week'} onChange={() => setGrain('week')} /> By week (Mon–Sun)</label>
      </div>
      {loading && <Loading what="sales" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Net sales" value={money(net)} hint="Gross sales − discounts − returns (ledger)" />
            <Stat label="Orders fulfilled" value={orders.toLocaleString()} hint={`${sum('units').toLocaleString()} units`} />
            <Stat label="Average order" value={orders > 0 ? money((sum('gross_sales') - sum('discounts')) / orders) : '—'} hint="(Gross − discounts) ÷ orders" />
            <Stat label="Gross profit" value={money(sum('gross_profit'))} hint={net > 0 ? `${pctText(sum('gross_profit') / net)} of net sales` : 'Net sales − COGS'} />
          </div>
          <h2>Net sales {grain === 'week' ? 'per week' : 'per day'}</h2>
          <BarChart
            title={`Net sales per ${grain}`}
            format={(v) => (Math.abs(v) >= 1000 ? `$${(v / 1000).toFixed(1)}k` : `$${v.toFixed(0)}`)}
            bars={data.map((r) => ({
              key: r.period_start,
              label: shortDate(r.period_start),
              value: Number(r.net_sales),
              tooltip: `${label(r)}: ${money(r.net_sales)} net sales, ${r.orders} orders, ${Number(r.units)} units`,
            }))}
          />
          <div className="table-wrap" style={{ marginTop: '0.75rem' }}>
            <table className="table">
              <thead>
                <tr>
                  <th>{grain === 'week' ? 'Week starting' : 'Day'}</th>
                  <th className="num">Orders</th>
                  <th className="num">Units</th>
                  <th className="num">Gross sales</th>
                  <th className="num">Discounts</th>
                  <th className="num">Returns</th>
                  <th className="num">Net sales</th>
                  <th className="num">COGS</th>
                  <th className="num">Gross profit</th>
                </tr>
              </thead>
              <tbody>
                {[...data].reverse().map((r) => (
                  <tr key={r.period_start}>
                    <td>{grain === 'week' ? shortDate(r.period_start) : new Date(`${r.period_start}T12:00:00`).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })}</td>
                    <td className={`num ${Number(r.orders) === 0 ? 'zero' : ''}`}>{r.orders}</td>
                    <td className="num">{Number(r.units).toLocaleString()}</td>
                    <td className="num">{money(r.gross_sales)}</td>
                    <td className="num">{Number(r.discounts) ? `−${money(r.discounts)}` : '—'}</td>
                    <td className="num">{Number(r.returns) ? `−${money(r.returns)}` : '—'}</td>
                    <td className="num strong">{money(r.net_sales)}</td>
                    <td className="num">{money(r.cogs)}</td>
                    <td className="num">{money(r.gross_profit)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td>Total</td>
                  <td className="num">{orders}</td>
                  <td className="num">{sum('units').toLocaleString()}</td>
                  <td className="num">{money(sum('gross_sales'))}</td>
                  <td className="num">−{money(sum('discounts'))}</td>
                  <td className="num">−{money(sum('returns'))}</td>
                  <td className="num">{money(net)}</td>
                  <td className="num">{money(sum('cogs'))}</td>
                  <td className="num">{money(sum('gross_profit'))}</td>
                </tr>
              </tfoot>
            </table>
          </div>
          <p className="muted small">Revenue is counted when an order is fulfilled (that is when the sale posts to the ledger). Returns are counted on the day they were processed.</p>
        </>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
interface TopRow {
  item_id: string;
  sku: string;
  name: string;
  product_family: string | null;
  orders: number;
  units_sold: number;
  net_revenue: number;
  cogs: number;
  gross_profit: number;
  margin_pct: number | null;
  units_returned: number;
  returned_value: number;
}

function TopSellersReport({ from, to, range }: { from: string; to: string; range: ReactNode }) {
  const [by, setBy] = useState<'revenue' | 'units' | 'profit'>('revenue');
  const [group, setGroup] = useState<'item' | 'product'>('item');
  const { data, error, loading } = useLiveQuery(
    async () => unwrap<TopRow[]>(await db().rpc('top_sellers', { p_from: from, p_to: to })),
    ['sales_orders', 'returns'],
    [from, to],
  );

  let rows = data ?? [];
  if (group === 'product') {
    const m = new Map<string, TopRow>();
    for (const r of rows) {
      const k = r.product_family ?? r.name;
      const g = m.get(k);
      if (!g) m.set(k, { ...r, item_id: k, name: k, sku: '' });
      else {
        g.orders = Number(g.orders) + Number(r.orders); // orders may contain more than one color
        g.units_sold = Number(g.units_sold) + Number(r.units_sold);
        g.net_revenue = Number(g.net_revenue) + Number(r.net_revenue);
        g.cogs = Number(g.cogs) + Number(r.cogs);
        g.gross_profit = Number(g.gross_profit) + Number(r.gross_profit);
        g.units_returned = Number(g.units_returned) + Number(r.units_returned);
        g.returned_value = Number(g.returned_value) + Number(r.returned_value);
      }
    }
    rows = [...m.values()].map((g) => ({ ...g, margin_pct: Number(g.net_revenue) > 0 ? Number(g.gross_profit) / Number(g.net_revenue) : null }));
  }
  const key = by === 'units' ? 'units_sold' : by === 'profit' ? 'gross_profit' : 'net_revenue';
  rows = [...rows].sort((a, b) => Number(b[key]) - Number(a[key]));
  const totalRevenue = rows.reduce((s, r) => s + Number(r.net_revenue), 0);
  const top = rows.slice(0, 10);

  return (
    <>
      {range}
      <div className="choice-row spaced">
        <span className="muted">Rank by</span>
        <label className="check"><input type="radio" checked={by === 'revenue'} onChange={() => setBy('revenue')} /> Revenue</label>
        <label className="check"><input type="radio" checked={by === 'units'} onChange={() => setBy('units')} /> Units</label>
        <label className="check"><input type="radio" checked={by === 'profit'} onChange={() => setBy('profit')} /> Gross profit</label>
        <span className="muted">· Show</span>
        <label className="check"><input type="radio" checked={group === 'item'} onChange={() => setGroup('item')} /> Each item (color)</label>
        <label className="check"><input type="radio" checked={group === 'product'} onChange={() => setGroup('product')} /> Product (all colors)</label>
      </div>
      {loading && <Loading what="top sellers" />}
      {error && <ErrorNotice message={error} />}
      {data && rows.length === 0 && <p className="muted">Nothing was sold in this period.</p>}
      {data && rows.length > 0 && (
        <>
          <BarChart
            title="Top sellers"
            format={by === 'units' ? (v) => v.toFixed(0) : (v) => `$${v.toFixed(0)}`}
            bars={top.map((r, i) => ({
              key: r.item_id,
              label: `#${i + 1}`,
              value: Number(r[key]),
              tooltip: `#${i + 1} ${r.name}: ${by === 'units' ? `${Number(r.units_sold)} units` : money(r[key])}`,
            }))}
          />
          <div className="table-wrap" style={{ marginTop: '0.75rem' }}>
            <table className="table">
              <thead>
                <tr>
                  <th>#</th>
                  <th>{group === 'item' ? 'Item' : 'Product'}</th>
                  <th className="num">Units sold</th>
                  <th className="num">Net revenue</th>
                  <th className="num">Share</th>
                  <th className="num">COGS</th>
                  <th className="num">Gross profit</th>
                  <th className="num">Margin</th>
                  <th className="num">Returned</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r, i) => (
                  <tr key={r.item_id}>
                    <td className="muted">{i + 1}</td>
                    <td>
                      {group === 'item' ? <Link to={`/inventory/item/${r.item_id}`}>{r.name}</Link> : r.name}
                      {r.sku && <div className="muted small">{r.sku}</div>}
                    </td>
                    <td className="num">{Number(r.units_sold).toLocaleString()}</td>
                    <td className="num strong">{money(r.net_revenue)}</td>
                    <td className="num muted">{totalRevenue > 0 ? pctText(Number(r.net_revenue) / totalRevenue) : ''}</td>
                    <td className="num">{money(r.cogs)}</td>
                    <td className="num">{money(r.gross_profit)}</td>
                    <td className="num">{pctText(r.margin_pct)}</td>
                    <td className="num">{Number(r.units_returned) > 0 ? `${Number(r.units_returned)} (${money(r.returned_value)})` : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="muted small">Net revenue = units × price after the order discount. COGS = units × weighted-average cost when the order was fulfilled.</p>
        </>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
function LowStockReport() {
  const { data, error, loading } = useLiveQuery(loadReorderPlan, reorderTables);
  const [all, setAll] = useState(false);
  const rows = (data?.rows ?? [])
    .filter((r) => (all ? Number(r.avg_daily) > 0 && r.order_by_date !== null && r.order_by_date <= addDays(localToday(), 7) : r.below_reorder_point))
    .sort((a, b) => (a.order_by_date ?? '').localeCompare(b.order_by_date ?? '') || Number(a.days_of_supply ?? 0) - Number(b.days_of_supply ?? 0));
  const show = (r: ReorderRow, v: number | null) => (v === null ? '—' : r.uom === 'g' ? qty(v, 'g') : n(v, 1));

  return (
    <>
      <div className="choice-row spaced">
        <label className="check"><input type="radio" checked={!all} onChange={() => setAll(false)} /> At or below the reorder point now</label>
        <label className="check"><input type="radio" checked={all} onChange={() => setAll(true)} /> Will reach it within 7 days</label>
      </div>
      {loading && <Loading what="stock levels" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Items to reorder now" value={data.rows.filter((r) => r.below_reorder_point).length} tone={data.rows.some((r) => r.below_reorder_point) ? 'warn' : undefined} />
            <Stat label="Purchased items low" value={data.rows.filter((r) => r.below_reorder_point && r.replenish_by === 'purchase').length} hint={<Link to="/purchasing/planning">Reorder planning → create POs</Link>} />
            <Stat label="Made items low" value={data.rows.filter((r) => r.below_reorder_point && r.replenish_by === 'production').length} hint={<Link to="/production/new">New production order</Link>} />
          </div>
          {rows.length === 0 ? (
            <p className="notice ok">Nothing is low. Every item with demand is above its reorder point.</p>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Item</th>
                    <th>Replenish by</th>
                    <th className="num">Position</th>
                    <th className="num">Reorder point</th>
                    <th className="num">Days of supply</th>
                    <th className="num">Suggested qty</th>
                    <th>Order by</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.item_id} className={r.below_reorder_point ? 'row-alert' : ''}>
                      <td><Link to={`/inventory/item/${r.item_id}`}>{r.name}</Link><div className="muted small">{r.sku}</div></td>
                      <td>{r.replenish_by === 'purchase' ? (r.supplier_name ?? 'Purchase') : 'Production'}<div className="muted small">lead time {r.lead_days} d</div></td>
                      <td className="num">{show(r, Number(r.position))}<div className="muted small">on hand {show(r, Number(r.on_hand))} + on order {show(r, Number(r.on_order))} − committed {show(r, Number(r.committed))}</div></td>
                      <td className="num">{show(r, Number(r.reorder_point))}</td>
                      <td className="num">{r.days_of_supply === null ? '—' : n(r.days_of_supply, 1)}</td>
                      <td className="num strong">
                        {r.suggested_qty === null
                          ? '—'
                          : r.uom === 'g'
                            ? `${r.suggested_units} ${r.purchase_uom}${Number(r.suggested_units) === 1 ? '' : 's'}`
                            : `${n(r.suggested_qty, 0)}`}
                        {r.eoq !== null && <div className="muted small">EOQ {show(r, Number(r.eoq))}</div>}
                      </td>
                      <td className={r.order_by_date && r.order_by_date <= localToday() ? 'bad strong' : ''}>{r.order_by_date ? date(r.order_by_date) : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <p className="muted small">Reorder point = average daily usage × lead time + z × σ × √lead time; suggested quantity = EOQ (or enough to get back above the reorder point). Order-by = the day the position is expected to reach the reorder point. Same view as Reorder planning.</p>
        </>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
async function loadByLocation() {
  const c = db();
  const [items, locations, avail] = await Promise.all([
    c.from('items').select('id, sku, name, category, uom').eq('is_active', true).order('name').then(unwrap<Pick<Item, 'id' | 'sku' | 'name' | 'category' | 'uom'>[]>),
    c.from('locations').select('*').eq('is_active', true).order('sort_order').then(unwrap<Location[]>),
    c.from('v_availability').select('*').then(unwrap<Availability[]>),
  ]);
  return { items, locations, avail: new Map(avail.map((a) => [`${a.item_id}|${a.location_id}`, a])) };
}

function StockByLocationReport() {
  const { data, error, loading } = useLiveQuery(loadByLocation, ['inventory_txn', 'sales_orders', 'sales_order_lines', 'items']);
  const [cat, setCat] = useState('product');
  return (
    <>
      <div className="choice-row spaced">
        {[['product', 'Products'], ['filament', 'Filament'], ['component', 'Components'], ['packaging', 'Packaging']].map(([k, l]) => (
          <label key={k} className="check"><input type="radio" checked={cat === k} onChange={() => setCat(k)} /> {l}</label>
        ))}
      </div>
      {loading && <Loading what="inventory" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Item</th>
                {data.locations.map((l) => <th key={l.id} className="num">{shortLocation(l)}{!l.is_sellable && <div className="muted small">not sellable</div>}</th>)}
                <th className="num">Total on hand</th>
              </tr>
            </thead>
            <tbody>
              {data.items.filter((i) => i.category === cat).map((i) => {
                let total = 0;
                return (
                  <tr key={i.id}>
                    <td><Link to={`/inventory/item/${i.id}`}>{i.name}</Link><div className="muted small">{i.sku}</div></td>
                    {data.locations.map((l) => {
                      const a = data.avail.get(`${i.id}|${l.id}`);
                      const oh = Number(a?.qty_on_hand ?? 0);
                      total += oh;
                      return (
                        <td key={l.id} className={`num ${oh === 0 ? 'zero' : ''}`}>
                          {qty(oh, i.uom)}
                          {a && Number(a.qty_committed) > 0 && <div className="muted small">{qty(a.qty_available, i.uom)} available</div>}
                        </td>
                      );
                    })}
                    <td className="num strong">{qty(total, i.uom)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <p className="muted small">On hand = sum of posted stock movements at that location. Available = on hand − reserved for open sales orders.</p>
    </>
  );
}

// ---------------------------------------------------------------------------
interface ScoreRow {
  supplier_id: string;
  name: string;
  quoted_lead_days: number;
  payment_terms: string;
  pos_delivered: number;
  on_time_rate: number | null;
  avg_actual_lead_days: number | null;
  avg_quoted_lead_days: number | null;
  avg_days_late: number | null;
  fill_rate: number | null;
  amount_owed: number;
  next_due_date: string | null;
  overall_score: number | null;
  rating: string;
}

function SupplierPerformanceReport() {
  const { data, error, loading } = useLiveQuery(
    async () => unwrap<ScoreRow[]>(await db().from('v_supplier_scorecard').select('*').order('name')),
    ['purchase_orders', 'po_receipts', 'purchase_order_lines', 'suppliers'],
  );
  return (
    <>
      {loading && <Loading what="supplier performance" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Supplier</th>
                <th className="num">POs delivered</th>
                <th className="num">Quoted lead</th>
                <th className="num">Actual lead (avg)</th>
                <th className="num">Difference</th>
                <th className="num">On time</th>
                <th className="num">Fill rate</th>
                <th className="num">Owed</th>
                <th className="num">Score</th>
                <th>Rating</th>
              </tr>
            </thead>
            <tbody>
              {data.map((s) => {
                const diff = s.avg_actual_lead_days === null || s.avg_quoted_lead_days === null ? null : Number(s.avg_actual_lead_days) - Number(s.avg_quoted_lead_days);
                return (
                  <tr key={s.supplier_id}>
                    <td><Link to={`/suppliers/${s.supplier_id}`}>{s.name}</Link><div className="muted small">{s.payment_terms}</div></td>
                    <td className="num">{s.pos_delivered}</td>
                    <td className="num">{n(s.avg_quoted_lead_days ?? s.quoted_lead_days, 1)} d</td>
                    <td className="num">{s.avg_actual_lead_days === null ? '—' : `${n(s.avg_actual_lead_days, 1)} d`}</td>
                    <td className={`num ${diff !== null && diff > 0.5 ? 'bad' : diff !== null && diff <= 0 ? 'good' : ''}`}>{diff === null ? '—' : `${diff > 0 ? '+' : ''}${diff.toFixed(1)} d`}</td>
                    <td className="num">{pctText(s.on_time_rate)}</td>
                    <td className="num">{pctText(s.fill_rate)}</td>
                    <td className="num">{money(s.amount_owed)}{s.next_due_date && <div className="muted small">next due {date(s.next_due_date)}</div>}</td>
                    <td className="num strong">{s.overall_score === null ? '—' : n(s.overall_score, 1)}</td>
                    <td><span className={`rating ${s.rating.toLowerCase()}`}>{s.rating}</span></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <p className="muted small">From purchase-order history: actual lead = last receipt date − sent date; on time = received by the expected date; fill rate = value received ÷ value ordered. Score = on-time 40% + fill rate 30% + lead-time accuracy 20% + price stability 10%. Full scorecard: <Link to="/suppliers">Suppliers & scorecard</Link>.</p>
    </>
  );
}
