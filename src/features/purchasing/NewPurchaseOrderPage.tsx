import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { date, money, qty, unitCost } from '../../lib/format';
import type { Item, ItemSupplier, Location, Supplier } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { addDays, localToday } from '../production/productionShared';

interface Line {
  item_id: string;
  qty: string;
  unit_cost: string;
}

async function load() {
  const c = db();
  const [suppliers, prices, items, locations] = await Promise.all([
    c.from('suppliers').select('*').eq('is_active', true).order('name').then(unwrap<Supplier[]>),
    c.from('item_suppliers').select('*').then(unwrap<ItemSupplier[]>),
    c.from('items').select('*').eq('is_active', true).order('name').then(unwrap<Item[]>),
    c.from('locations').select('*').eq('is_active', true).order('sort_order').then(unwrap<Location[]>),
  ]);
  return { suppliers, prices, items: new Map(items.map((i) => [i.id, i])), locations };
}

export function NewPurchaseOrderPage() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { data, error, loading } = useLiveQuery(load, ['suppliers', 'item_suppliers', 'items']);
  const [supplierId, setSupplierId] = useState(params.get('supplier') ?? '');
  const [shipTo, setShipTo] = useState('');
  const [lines, setLines] = useState<Line[]>([]);
  const [notes, setNotes] = useState('');
  const [send, setSend] = useState(true);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const priceList = useMemo(() => (data ? data.prices.filter((p) => p.supplier_id === supplierId) : []), [data, supplierId]);
  const supplier = data?.suppliers.find((s) => s.id === supplierId);

  // Defaults: ship to the Print Farm; prefill one line from ?item=&qty= (reorder planning links here).
  useEffect(() => {
    if (!data) return;
    if (!shipTo) setShipTo(data.locations.find((l) => l.code === 'PRINT_FARM')?.id ?? '');
  }, [data, shipTo]);
  useEffect(() => {
    const item = params.get('item');
    if (!data || !item || lines.length > 0) return;
    const p = data.prices.find((x) => x.item_id === item && x.supplier_id === supplierId);
    if (p) setLines([{ item_id: item, qty: params.get('qty') ?? '1', unit_cost: String(p.unit_cost) }]);
  }, [data, params, supplierId, lines.length]);

  if (loading) return <Loading what="suppliers" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;

  function addLine(itemId: string) {
    const p = priceList.find((x) => x.item_id === itemId);
    if (!p || lines.some((l) => l.item_id === itemId)) return;
    setLines([...lines, { item_id: itemId, qty: '1', unit_cost: String(p.unit_cost) }]);
  }

  const parsed = lines.map((l) => ({ ...l, n: Number(l.qty), c: Number(l.unit_cost) }));
  const valid = supplier && parsed.length > 0 && parsed.every((l) => l.n > 0 && l.c >= 0 && Number.isFinite(l.n) && Number.isFinite(l.c));
  const total = parsed.reduce((s, l) => s + (l.n > 0 ? l.n * l.c : 0), 0);

  async function submit() {
    if (!valid) return;
    setBusy(true);
    setErr(null);
    try {
      const id = await rpc<string>('create_purchase_order', {
        p: {
          supplier_id: supplierId,
          ship_to_location_id: shipTo || null,
          notes: notes.trim() || null,
          send,
          lines: parsed.map((l) => ({ item_id: l.item_id, qty: l.n, unit_cost: l.c })),
        },
      });
      navigate(`/purchasing/${id}`);
    } catch (e) {
      setErr(errorMessage(e));
      setBusy(false);
    }
  }

  return (
    <div>
      <PageHeader
        title="New purchase order"
        subtitle="Quantities are in the supplier's purchase unit (filament in 985 g spools). Prices default from the supplier's price list."
        actions={<Link className="btn" to="/purchasing">All purchase orders</Link>}
      />
      <form
        className="form card"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        <div className="form-row">
          <label className="grow">
            Supplier
            <select value={supplierId} onChange={(e) => { setSupplierId(e.target.value); setLines([]); }} required>
              <option value="">Choose a supplier…</option>
              {data.suppliers.map((s) => (
                <option key={s.id} value={s.id}>{s.name} ({s.quoted_lead_days} days, {s.payment_terms})</option>
              ))}
            </select>
          </label>
          <label>
            Ship to
            <select value={shipTo} onChange={(e) => setShipTo(e.target.value)}>
              {data.locations.filter((l) => l.is_sellable).map((l) => (
                <option key={l.id} value={l.id}>{l.name}</option>
              ))}
            </select>
          </label>
        </div>

        {supplier && (
          <>
            <p className="muted small">
              Expected receipt if sent today: <strong>{date(addDays(localToday(), supplier.quoted_lead_days))}</strong> (today + {supplier.quoted_lead_days}-day quoted lead time).
              Payment: {supplier.payment_terms}{supplier.terms_days > 0 ? ` — each receipt becomes a bill due ${supplier.terms_days} days after it arrives.` : ' — paid automatically when received.'}
            </p>
            <label>
              Add an item this supplier sells
              <select value="" onChange={(e) => addLine(e.target.value)}>
                <option value="">Choose…</option>
                {priceList.map((p) => (
                  <option key={p.item_id} value={p.item_id} disabled={lines.some((l) => l.item_id === p.item_id)}>
                    {data.items.get(p.item_id)?.name} — {unitCost(p.unit_cost)} per {p.purchase_uom}
                  </option>
                ))}
              </select>
            </label>
          </>
        )}

        {lines.length > 0 && (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="num">Quantity</th>
                  <th className="num">Unit cost</th>
                  <th className="num">Stock units</th>
                  <th className="num">Line total</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {lines.map((l, i) => {
                  const p = priceList.find((x) => x.item_id === l.item_id);
                  const item = data.items.get(l.item_id);
                  const n = Number(l.qty);
                  return (
                    <tr key={l.item_id}>
                      <td>{item?.name}<div className="muted small">{item?.sku}</div></td>
                      <td className="num">
                        <input className="qty-input" type="number" min={0} step="any" value={l.qty}
                          onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} />
                        <span className="muted small"> {p?.purchase_uom}</span>
                      </td>
                      <td className="num">
                        <input className="qty-input" type="number" min={0} step="0.01" value={l.unit_cost}
                          onChange={(e) => setLines(lines.map((x, j) => (j === i ? { ...x, unit_cost: e.target.value } : x)))} />
                      </td>
                      <td className="num muted">{n > 0 ? qty(n * Number(p?.stock_per_purchase_unit ?? 1), item?.uom) : '—'}</td>
                      <td className="num">{n > 0 ? money(n * Number(l.unit_cost)) : '—'}</td>
                      <td><button type="button" className="btn link" onClick={() => setLines(lines.filter((_, j) => j !== i))}>Remove</button></td>
                    </tr>
                  );
                })}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan={4}>Total</td>
                  <td className="num">{money(total)}</td>
                  <td></td>
                </tr>
              </tfoot>
            </table>
          </div>
        )}

        <label>
          Notes
          <input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Optional" />
        </label>
        <label className="check">
          <input type="checkbox" checked={send} onChange={(e) => setSend(e.target.checked)} />
          Send to the supplier now (status Order sent, expected date set)
        </label>
        {err && <ErrorNotice message={err} />}
        <div className="page-actions">
          <button className="btn primary" disabled={!valid || busy}>{busy ? 'Saving…' : send ? 'Create & send PO' : 'Save draft'}</button>
        </div>
      </form>
    </div>
  );
}
