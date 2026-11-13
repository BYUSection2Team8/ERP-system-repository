import { useState } from 'react';
import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat, shortLocation } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { date, money, qty, unitCost } from '../../lib/format';
import type { Item, Location, Turnover } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { categoryLabels } from '../inventory/useInventoryData';
import { addDays, localToday } from '../production/productionShared';

interface ValRow {
  item_id: string;
  sku: string;
  name: string;
  category: string;
  uom: 'ea' | 'g';
  qty_on_hand: number;
  avg_unit_cost: number;
  inventory_value: number;
}
interface LocRow {
  item_id: string;
  location_id: string;
  qty_on_hand: number;
  inventory_value: number;
}

async function load(from: string, to: string) {
  const c = db();
  const [turn, vals, byLoc, locations, items, balances] = await Promise.all([
    c.rpc('inventory_turnover', { p_from: from, p_to: to }).then((r) => unwrap<Turnover[]>(r)[0]),
    c.from('v_inventory_valuation').select('*').then(unwrap<ValRow[]>),
    c.from('v_inventory_by_location').select('item_id, location_id, qty_on_hand, inventory_value').then(unwrap<LocRow[]>),
    c.from('locations').select('*').order('sort_order').then(unwrap<Location[]>),
    c.from('items').select('id, category').then(unwrap<Pick<Item, 'id' | 'category'>[]>),
    c.from('v_account_balances').select('code, balance').in('code', ['1200', '1250']).then(unwrap<{ code: string; balance: number }[]>),
  ]);
  return {
    turn,
    vals: vals.filter((v) => Number(v.qty_on_hand) !== 0).sort((a, b) => Number(b.inventory_value) - Number(a.inventory_value)),
    byLoc,
    locations,
    category: new Map(items.map((i) => [i.id, i.category])),
    books: Number(balances.find((b) => b.code === '1200')?.balance ?? 0),
    wip: Number(balances.find((b) => b.code === '1250')?.balance ?? 0),
  };
}

const categories = ['product', 'filament', 'component', 'packaging'];

export function InventoryValuationPage() {
  const today = localToday();
  const presets = [
    { label: 'Last 30 days', days: 30 },
    { label: 'Last 90 days', days: 90 },
    { label: 'Last 180 days', days: 180 },
  ];
  const [from, setFrom] = useState(addDays(today, -89));
  const [to, setTo] = useState(today);
  const { data, error, loading } = useLiveQuery(() => load(from, to), ['ledger', 'inventory_txn'], [from, to]);

  return (
    <div>
      <PageHeader
        title="Inventory valuation & turnover"
        subtitle="Stock is valued at weighted-average cost from the stock movements; the ledger's Inventory account must agree. Turnover = cost of goods sold ÷ average inventory value."
        actions={<Link className="btn" to="/inventory">Inventory by item</Link>}
      />
      {loading && <Loading what="valuation" />}
      {error && <ErrorNotice message={error} />}
      {data && (() => {
        const total = data.vals.reduce((s, v) => s + Number(v.inventory_value), 0);
        const diff = data.books - total;
        const t = data.turn;
        const cell = (cat: string, loc: string) =>
          data.byLoc.filter((r) => r.location_id === loc && data.category.get(r.item_id) === cat).reduce((s, r) => s + Number(r.inventory_value), 0);
        return (
          <>
            <div className="stats">
              <Stat label="Inventory value (weighted average)" value={money(total)} hint={`${data.vals.length} items in stock`} />
              <Stat
                label="Inventory on the books (ledger 1200)"
                value={money(data.books)}
                hint={Math.abs(diff) < 1 ? 'Agrees with the valuation' : `${money(diff)} rounding difference`}
                tone={Math.abs(diff) > Math.max(5, total * 0.01) ? 'bad' : undefined}
              />
              <Stat label="Work in process (ledger 1250)" value={money(data.wip)} hint="Components issued to open production orders" />
              <Stat
                label="Inventory turnover (annualized)"
                value={t.annualized_turnover === null ? '—' : `${Number(t.annualized_turnover).toFixed(1)}×`}
                hint={t.days_of_inventory === null ? '' : `≈ ${Number(t.days_of_inventory).toFixed(0)} days of inventory`}
              />
            </div>

            <h2>Turnover</h2>
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
                  <button key={p.label} type="button" className="btn" onClick={() => { setFrom(addDays(today, -(p.days - 1))); setTo(today); }}>{p.label}</button>
                ))}
              </div>
            </div>
            <div className="card">
              <table className="totals">
                <tbody>
                  <tr><td>Cost of goods sold, {date(from)} – {date(to)} ({t.days} days)</td><td className="num">{money(t.cogs)}</td></tr>
                  <tr><td>Inventory at the start / end</td><td className="num">{money(t.begin_inventory)} / {money(t.end_inventory)}</td></tr>
                  <tr><td>Average inventory (mean of each day's ending ledger balance)</td><td className="num">{money(t.avg_inventory)}</td></tr>
                  <tr className="grand"><td>Turnover for the period = COGS ÷ average inventory</td><td className="num">{t.turnover === null ? '—' : `${Number(t.turnover).toFixed(2)}×`}</td></tr>
                  <tr><td>Annualized = turnover × 365 ÷ {t.days}</td><td className="num">{t.annualized_turnover === null ? '—' : `${Number(t.annualized_turnover).toFixed(2)}×`}</td></tr>
                  <tr><td>Days of inventory = {t.days} ÷ turnover</td><td className="num">{t.days_of_inventory === null ? '—' : Number(t.days_of_inventory).toFixed(1)}</td></tr>
                </tbody>
              </table>
            </div>

            <h2>Value by location</h2>
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th></th>
                    {data.locations.map((l) => <th key={l.id} className="num">{shortLocation(l)}</th>)}
                    <th className="num">Total</th>
                  </tr>
                </thead>
                <tbody>
                  {categories.map((cat) => (
                    <tr key={cat}>
                      <td>{categoryLabels[cat]}</td>
                      {data.locations.map((l) => <td key={l.id} className="num">{money(cell(cat, l.id))}</td>)}
                      <td className="num strong">{money(data.locations.reduce((s, l) => s + cell(cat, l.id), 0))}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr>
                    <td>Total</td>
                    {data.locations.map((l) => <td key={l.id} className="num">{money(categories.reduce((s, c) => s + cell(c, l.id), 0))}</td>)}
                    <td className="num">{money(data.byLoc.reduce((s, r) => s + Number(r.inventory_value), 0))}</td>
                  </tr>
                </tfoot>
              </table>
            </div>

            <h2>By item</h2>
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Item</th>
                    <th>Category</th>
                    <th className="num">On hand</th>
                    <th className="num">Weighted-average cost</th>
                    <th className="num">Value</th>
                    <th className="num">Share</th>
                  </tr>
                </thead>
                <tbody>
                  {data.vals.map((v) => (
                    <tr key={v.item_id}>
                      <td><Link to={`/inventory/item/${v.item_id}`}>{v.name}</Link><div className="muted small">{v.sku}</div></td>
                      <td>{categoryLabels[v.category] ?? v.category}</td>
                      <td className="num">{qty(v.qty_on_hand, v.uom)}</td>
                      <td className="num">{unitCost(v.avg_unit_cost)}{v.uom === 'g' ? '/g' : ''}</td>
                      <td className="num">{money(v.inventory_value)}</td>
                      <td className="num muted">{total > 0 ? `${((Number(v.inventory_value) / total) * 100).toFixed(1)}%` : ''}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        );
      })()}
    </div>
  );
}
