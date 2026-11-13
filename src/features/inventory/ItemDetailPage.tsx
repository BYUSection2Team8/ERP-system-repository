import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat, shortLocation } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { dateTime, gramsInPacks, money, qty, sourceLabels, unitCost } from '../../lib/format';
import type { InventoryTxn } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { Barcode } from '../barcodes/Barcode';
import { categoryLabels, useInventoryData } from './useInventoryData';

interface StdCost {
  material_cost: number;
  machine_cost: number;
  labor_cost: number;
  total_cost: number;
  margin_pct: number | null;
}
interface BomLine {
  component_item_id: string;
  qty_per_plate: number;
  qty_per_unit: number;
}
interface SupplierPrice {
  unit_cost: number;
  purchase_uom: string;
  stock_per_purchase_unit: number;
  is_preferred: boolean;
  suppliers: { name: string; quoted_lead_days: number; payment_terms: string } | null;
}

const policyLabels: Record<string, string> = {
  stock: 'Stocked',
  make_to_order: 'Made to order',
  seasonal: 'Seasonal',
  not_sold: 'Not sold (purchased input)',
};

export function ItemDetailPage() {
  const { id = '' } = useParams();
  const inv = useInventoryData();
  const detail = useLiveQuery(
    async () => {
      const c = db();
      const [txns, std, bom, suppliers] = await Promise.all([
        c.from('inventory_txn')
          .select('id, txn_at, item_id, location_id, qty, unit_cost, ext_cost, source_type, reason_code, note')
          .eq('item_id', id)
          .order('txn_at', { ascending: false })
          .order('id', { ascending: false })
          .limit(100)
          .then(unwrap<InventoryTxn[]>),
        c.from('v_item_standard_cost').select('*').eq('item_id', id).maybeSingle().then(unwrap<StdCost | null>),
        c.from('v_bom_per_unit').select('component_item_id, qty_per_plate, qty_per_unit').eq('parent_item_id', id).then(unwrap<BomLine[]>),
        c.from('item_suppliers')
          .select('unit_cost, purchase_uom, stock_per_purchase_unit, is_preferred, suppliers(name, quoted_lead_days, payment_terms)')
          .eq('item_id', id)
          // The type guesser thinks the embedded supplier is an array; PostgREST
          // returns one object because item_suppliers.supplier_id is a foreign key.
          .then((r) => unwrap(r) as unknown as SupplierPrice[]),
      ]);
      return { txns, std, bom, suppliers };
    },
    ['inventory_txn'],
    [id],
  );

  if (inv.loading || detail.loading) return <Loading what="item" />;
  if (inv.error) return <ErrorNotice message={inv.error} />;
  if (detail.error) return <ErrorNotice message={detail.error} />;
  if (!inv.data || !detail.data) return null;

  const { items, locations, valuation, packOf, at } = inv.data;
  const item = items.find((i) => i.id === id);
  if (!item) return <ErrorNotice message="Item not found." />;
  const { txns, std, bom, suppliers } = detail.data;
  const v = valuation.get(item.id);
  const itemById = new Map(items.map((i) => [i.id, i]));
  const locById = new Map(locations.map((l) => [l.id, l]));
  const total = Number(v?.qty_on_hand ?? 0);

  return (
    <div>
      <PageHeader
        title={item.name}
        subtitle={`${item.sku} · ${categoryLabels[item.category]} · ${policyLabels[item.stocking_policy]}`}
        actions={
          <>
            <Link className="btn" to={`/inventory/transfer?item=${item.id}`}>Transfer</Link>
            <Link className="btn" to={`/inventory/adjust?item=${item.id}`}>Adjust / count</Link>
            <Link className="btn" to={`/labels?item=${item.id}`}>Print label</Link>
            {item.item_type === 'finished' && <RetireButton family={item.product_family ?? ''} name={item.product_family ?? item.name} itemId={item.id} />}
          </>
        }
      />

      <div className="detail-grid">
        <div className="card">
          <div className="barcode-box">
            <Barcode value={item.barcode} height={50} moduleWidth={1.6} />
          </div>
          <dl className="facts">
            <dt>Barcode</dt><dd>{item.barcode}</dd>
            {item.price !== null && (<><dt>Price</dt><dd>{money(item.price)}</dd></>)}
            <dt>Stock unit</dt><dd>{item.uom === 'g' ? 'grams' : 'each'}</dd>
            {item.item_type === 'finished' && (
              <>
                <dt>Per plate</dt><dd>{item.units_per_plate} unit(s), {item.print_minutes} min print, {item.assembly_minutes ?? 0} min assembly</dd>
                <dt>Production lead time</dt><dd>{item.lead_time_days ?? '—'} day(s)</dd>
              </>
            )}
          </dl>
        </div>

        <div className="stats stack">
          <Stat label="On hand, all locations" value={item.uom === 'g' ? gramsInPacks(total, packOf(item.id)) : qty(total)} />
          <Stat label="Weighted-average cost" value={`${unitCost(v?.avg_unit_cost)}${item.uom === 'g' ? ' per g' : ''}`} />
          <Stat label="Inventory value" value={money(v?.inventory_value)} hint="on hand × weighted-average cost" />
        </div>
      </div>

      <h2>By location</h2>
      <table className="table">
        <thead>
          <tr><th>Location</th><th className="num">On hand</th><th className="num">On open orders</th><th className="num">Available</th></tr>
        </thead>
        <tbody>
          {locations.map((l) => {
            const a = at(item.id, l.id);
            const available = Number(a?.qty_available ?? 0);
            return (
              <tr key={l.id}>
                <td>{l.name}{!l.is_sellable && <span className="badge">not sellable</span>}</td>
                <td className="num">{qty(a?.qty_on_hand ?? 0, item.uom)}</td>
                <td className="num">{qty(a?.qty_committed ?? 0, item.uom)}</td>
                <td className={`num ${available < 0 ? 'bad' : ''}`}>{qty(available, item.uom)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>

      {std && (
        <>
          <h2>Rolled-up cost (per unit)</h2>
          <p className="muted small">
            From the bill of material at current weighted-average component costs, plus machine time and labor
            from Settings, divided by {item.units_per_plate} unit(s) per plate.
          </p>
          <table className="table narrow">
            <tbody>
              <tr><td>Materials</td><td className="num">{unitCost(std.material_cost)}</td></tr>
              <tr><td>Machine time</td><td className="num">{unitCost(std.machine_cost)}</td></tr>
              <tr><td>Labor (setup, cleanup, assembly)</td><td className="num">{unitCost(std.labor_cost)}</td></tr>
              <tr className="strong"><td>Unit cost</td><td className="num">{unitCost(std.total_cost)}</td></tr>
              {item.price !== null && std.margin_pct !== null && (
                <tr><td>Margin at {money(item.price)}</td><td className="num">{(Number(std.margin_pct) * 100).toFixed(1)}%</td></tr>
              )}
            </tbody>
          </table>
        </>
      )}

      {bom.length > 0 && (
        <>
          <h2>Bill of material</h2>
          <table className="table">
            <thead>
              <tr><th>Component</th><th className="num">Per plate</th><th className="num">Per unit</th><th className="num">Avg cost</th><th className="num">Cost per unit</th></tr>
            </thead>
            <tbody>
              {bom.map((b) => {
                const comp = itemById.get(b.component_item_id);
                const cost = Number(valuation.get(b.component_item_id)?.avg_unit_cost ?? 0);
                return (
                  <tr key={b.component_item_id}>
                    <td>{comp ? <Link to={`/inventory/item/${comp.id}`}>{comp.name}</Link> : '?'}</td>
                    <td className="num">{qty(b.qty_per_plate, comp?.uom)}</td>
                    <td className="num">{qty(b.qty_per_unit, comp?.uom)}</td>
                    <td className="num">{unitCost(cost)}</td>
                    <td className="num">{unitCost(Number(b.qty_per_unit) * cost)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </>
      )}

      {suppliers.length > 0 && (
        <>
          <h2>Suppliers</h2>
          <table className="table">
            <thead>
              <tr><th>Supplier</th><th>Buys as</th><th className="num">Price</th><th className="num">Quoted lead time</th><th>Terms</th></tr>
            </thead>
            <tbody>
              {suppliers.map((s, idx) => (
                <tr key={idx}>
                  <td>{s.suppliers?.name}{s.is_preferred && <span className="badge ok">preferred</span>}</td>
                  <td>{s.purchase_uom}{Number(s.stock_per_purchase_unit) !== 1 && ` of ${qty(s.stock_per_purchase_unit, item.uom)}`}</td>
                  <td className="num">{unitCost(s.unit_cost)}</td>
                  <td className="num">{s.suppliers?.quoted_lead_days} days</td>
                  <td>{s.suppliers?.payment_terms}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}

      <h2>Stock movements</h2>
      <p className="muted small">The last 100 movements. On-hand quantities above are the sum of all of them.</p>
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr><th>When</th><th>What</th><th>Location</th><th className="num">Qty</th><th className="num">Unit cost</th><th className="num">Value</th><th>Reason / note</th></tr>
          </thead>
          <tbody>
            {txns.length === 0 && (
              <tr><td colSpan={7} className="muted">No movements yet.</td></tr>
            )}
            {txns.map((t) => {
              const loc = locById.get(t.location_id);
              const n = Number(t.qty);
              return (
                <tr key={t.id}>
                  <td>{dateTime(t.txn_at)}</td>
                  <td>{sourceLabels[t.source_type] ?? t.source_type}</td>
                  <td>{loc ? shortLocation(loc) : '?'}</td>
                  <td className={`num ${n < 0 ? 'bad' : 'good'}`}>{n > 0 ? '+' : ''}{qty(n, item.uom)}</td>
                  <td className="num">{unitCost(t.unit_cost)}</td>
                  <td className="num">{money(t.ext_cost)}</td>
                  <td className="small">{[t.reason_code, t.note].filter(Boolean).join(' · ')}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

/** Product lifecycle: retire every color of a product. History and stock stay; it just stops being sold or planned. */
function RetireButton({ family, name, itemId }: { family: string; name: string; itemId: string }) {
  const navigate = useNavigate();
  const [err, setErr] = useState<string | null>(null);
  async function retire() {
    if (!window.confirm(`Retire "${name}"? Every color stops showing in POS, sales orders and the customer portal. Past orders and stock movements stay.`)) return;
    try {
      const c = db();
      const res = family ? await c.from('items').update({ is_active: false }).eq('product_family', family) : await c.from('items').update({ is_active: false }).eq('id', itemId);
      if (res.error) throw new Error(res.error.message);
      navigate('/inventory');
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  }
  return (
    <>
      <button className="btn" onClick={retire}>Retire product</button>
      {err && <span className="bad small">{err}</span>}
    </>
  );
}
