import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat, shortLocation } from '../../app/ui';
import { grams, money, qty, unitCost } from '../../lib/format';
import { ScanItemInput } from '../barcodes/ScanItemInput';
import { categoryLabels, useInventoryData } from './useInventoryData';

export function InventoryPage() {
  const { data, error, loading } = useInventoryData();
  const [search, setSearch] = useState('');
  const [category, setCategory] = useState('all');
  const [inStockOnly, setInStockOnly] = useState(false);
  const navigate = useNavigate();

  if (loading) return <Loading what="inventory" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;

  const { items, locations, valuation, spoolGrams, at } = data;
  const t = search.trim().toLowerCase();
  const rows = items.filter((i) => {
    if (category !== 'all' && i.category !== category) return false;
    if (t && !`${i.name} ${i.sku} ${i.barcode}`.toLowerCase().includes(t)) return false;
    if (inStockOnly && Number(valuation.get(i.id)?.qty_on_hand ?? 0) <= 0) return false;
    return true;
  });

  const totalValue = items.reduce((s, i) => s + Number(valuation.get(i.id)?.inventory_value ?? 0), 0);
  const shownValue = rows.reduce((s, i) => s + Number(valuation.get(i.id)?.inventory_value ?? 0), 0);
  const shortCount = data.availability.filter((a) => Number(a.qty_available) < 0).length;
  const fgUnits = items
    .filter((i) => i.category === 'product')
    .reduce((s, i) => s + Number(valuation.get(i.id)?.qty_on_hand ?? 0), 0);

  return (
    <div>
      <PageHeader
        title="Inventory"
        subtitle="On hand by item and location. Every number comes from posted stock movements."
        actions={
          <>
            <Link className="btn" to="/inventory/transfer">Transfer</Link>
            <Link className="btn" to="/inventory/adjust">Adjust / count</Link>
            <Link className="btn" to="/labels">Print labels</Link>
          </>
        }
      />

      <div className="stats">
        <Stat label="Inventory value (weighted avg)" value={money(totalValue)} />
        <Stat label="Finished units on hand" value={qty(fgUnits)} />
        <Stat
          label="Item-locations short"
          value={shortCount}
          hint={<Link to="/inventory/backorders">See backorders</Link>}
          tone={shortCount > 0 ? 'warn' : undefined}
        />
      </div>

      <div className="toolbar">
        <div className="grow">
          <ScanItemInput
            items={items}
            onPick={(i) => navigate(`/inventory/item/${i.id}`)}
            placeholder="Scan or type to open an item"
          />
        </div>
        <input
          className="filter"
          placeholder="Filter list…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          aria-label="Filter list"
        />
        <select value={category} onChange={(e) => setCategory(e.target.value)} aria-label="Category">
          <option value="all">All categories</option>
          {Object.entries(categoryLabels).map(([k, v]) => (
            <option key={k} value={k}>{v}</option>
          ))}
        </select>
        <label className="check">
          <input type="checkbox" checked={inStockOnly} onChange={(e) => setInStockOnly(e.target.checked)} />
          In stock only
        </label>
      </div>

      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr>
              <th>Item</th>
              {locations.map((l) => (
                <th key={l.id} className="num">{shortLocation(l)}</th>
              ))}
              <th className="num">Total</th>
              <th className="num">Avg cost</th>
              <th className="num">Value</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((i) => {
              const v = valuation.get(i.id);
              const total = Number(v?.qty_on_hand ?? 0);
              return (
                <tr key={i.id} className="clickable" onClick={() => navigate(`/inventory/item/${i.id}`)}>
                  <td>
                    <div>{i.name}</div>
                    <div className="muted small">{i.sku} · {categoryLabels[i.category]}</div>
                  </td>
                  {locations.map((l) => {
                    const a = at(i.id, l.id);
                    const onHand = Number(a?.qty_on_hand ?? 0);
                    const committed = Number(a?.qty_committed ?? 0);
                    const available = Number(a?.qty_available ?? 0);
                    return (
                      <td key={l.id} className={`num ${onHand === 0 && committed === 0 ? 'zero' : ''}`}>
                        {qty(onHand, i.uom)}
                        {committed > 0 && (
                          <div className={`small ${available < 0 ? 'bad' : 'muted'}`}>
                            {available < 0 ? `short ${qty(-available, i.uom)}` : `avail ${qty(available, i.uom)}`}
                          </div>
                        )}
                      </td>
                    );
                  })}
                  <td className="num strong">{i.uom === 'g' ? grams(total, spoolGrams) : qty(total)}</td>
                  <td className="num">{unitCost(v?.avg_unit_cost)}{i.uom === 'g' ? '/g' : ''}</td>
                  <td className="num">{money(v?.inventory_value)}</td>
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr>
              <td colSpan={locations.length + 3}>{rows.length} items shown</td>
              <td className="num strong">{money(shownValue)}</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
  );
}
