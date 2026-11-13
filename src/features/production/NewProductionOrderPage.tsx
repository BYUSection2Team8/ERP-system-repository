import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, shortLocation } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import { money, qty, unitCost } from '../../lib/format';
import type { Item } from '../../lib/types';
import { useInventoryData } from '../inventory/useInventoryData';
import { addDays, localToday, useProductionRefData } from './productionShared';

export function NewProductionOrderPage() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const ref = useProductionRefData();
  const inv = useInventoryData();

  const [itemId, setItemId] = useState(params.get('item') ?? '');
  const [quantity, setQuantity] = useState(params.get('qty') ?? '');
  const [due, setDue] = useState(params.get('due') ?? '');
  const [buildLoc, setBuildLoc] = useState('');
  const [outLoc, setOutLoc] = useState('');
  const [notes, setNotes] = useState(params.get('notes') ?? '');
  const [issueNow, setIssueNow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const soId = params.get('so');

  const data = ref.data;
  // Defaults once reference data arrives: build at the Print Farm, output to Fulfillment.
  useEffect(() => {
    if (!data) return;
    if (!buildLoc) setBuildLoc(data.locations.find((l) => l.code === 'PRINT_FARM')?.id ?? '');
    if (!outLoc) setOutLoc(data.locations.find((l) => l.code === 'FULFILLMENT')?.id ?? '');
  }, [data, buildLoc, outLoc]);

  const item = data?.itemsById.get(itemId);
  useEffect(() => {
    if (item && !due) setDue(addDays(localToday(), item.lead_time_days ?? 1));
  }, [item, due]);

  const n = Number(quantity);
  const valid = item && Number.isFinite(n) && n > 0 && Number.isInteger(n);
  const plates = valid ? Math.ceil(n / item.units_per_plate) : 0;
  const started = plates * (item?.units_per_plate ?? 1);

  const families = useMemo(() => {
    const m = new Map<string, Item[]>();
    for (const i of data?.makeable ?? []) {
      const k = i.product_family ?? 'Other';
      m.set(k, [...(m.get(k) ?? []), i]);
    }
    return [...m.entries()];
  }, [data]);

  if (ref.loading || inv.loading) return <Loading what="products and stock" />;
  if (ref.error) return <ErrorNotice message={ref.error} />;
  if (inv.error) return <ErrorNotice message={inv.error} />;
  if (!data || !inv.data) return null;
  const stock = inv.data;

  const bom = item ? data.bom.get(item.id) ?? [] : [];
  const std = item ? data.standardCost.get(item.id) : undefined;
  const short = bom.filter((b) => (stock.at(b.component_item_id, buildLoc)?.qty_on_hand ?? 0) < b.qty_per_plate * plates);

  async function submit() {
    if (!item || !valid) return;
    setBusy(true);
    setErr(null);
    try {
      const id = await rpc<string>('create_production_order', {
        p_item: item.id,
        p_qty: n,
        p_due_date: due || null,
        p_so_id: soId,
        p_location: buildLoc || null,
        p_output_location: outLoc || null,
        p_notes: notes.trim() || null,
      });
      if (issueNow) await rpc('issue_production_order', { p_mo_id: id });
      navigate(`/production/${id}`);
    } catch (e) {
      setErr(errorMessage(e));
      setBusy(false);
    }
  }

  return (
    <div>
      <PageHeader
        title="New production order"
        subtitle="Choose an item we make. Whole plates are printed, so the quantity started is rounded up to full plates."
        actions={<Link className="btn" to="/production">All production orders</Link>}
      />
      <div className="detail-grid">
        <form
          className="form card"
          onSubmit={(e) => {
            e.preventDefault();
            void submit();
          }}
        >
          <div className="form-row">
            <label className="grow">
              Item
              <select value={itemId} onChange={(e) => { setItemId(e.target.value); setDue(''); }} required>
                <option value="">Choose a product…</option>
                {families.map(([fam, items]) => (
                  <optgroup key={fam} label={fam}>
                    {items.map((i) => (
                      <option key={i.id} value={i.id}>
                        {i.name} ({i.sku})
                      </option>
                    ))}
                  </optgroup>
                ))}
              </select>
            </label>
          </div>
          <div className="form-row">
            <label>
              Quantity wanted
              <input type="number" min={1} step={1} value={quantity} onChange={(e) => setQuantity(e.target.value)} required />
            </label>
            <label>
              Due date
              <input type="date" value={due} onChange={(e) => setDue(e.target.value)} />
            </label>
          </div>
          <div className="form-row">
            <label>
              Build at (components consumed here)
              <select value={buildLoc} onChange={(e) => setBuildLoc(e.target.value)}>
                {data.locations.filter((l) => l.is_sellable).map((l) => (
                  <option key={l.id} value={l.id}>{l.name}</option>
                ))}
              </select>
            </label>
            <label>
              Receive good units into
              <select value={outLoc} onChange={(e) => setOutLoc(e.target.value)}>
                {data.locations.filter((l) => l.is_sellable).map((l) => (
                  <option key={l.id} value={l.id}>{l.name}</option>
                ))}
              </select>
            </label>
          </div>
          <label>
            Notes
            <input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Optional" />
          </label>
          <label className="check">
            <input type="checkbox" checked={issueNow} onChange={(e) => setIssueNow(e.target.checked)} disabled={short.length > 0} />
            Issue components and start now
          </label>
          {soId && <p className="muted small">Linked to a sales order (made to order).</p>}
          {err && <ErrorNotice message={err} />}
          <div className="page-actions">
            <button className="btn primary" disabled={!valid || busy}>
              {busy ? 'Saving…' : issueNow ? 'Create and issue' : 'Create production order'}
            </button>
          </div>
        </form>

        <div>
          <h2 style={{ marginTop: 0 }}>What this order will do</h2>
          {!item ? (
            <p className="muted">Choose an item to see its bill of material.</p>
          ) : (
            <div className="card">
              <dl className="facts">
                <dt>Units per plate</dt>
                <dd>{item.units_per_plate}</dd>
                <dt>Plates</dt>
                <dd>{valid ? `${plates} (${started} units started${started !== n ? `, ${started - n} extra to fill the last plate` : ''})` : '—'}</dd>
                <dt>Print time</dt>
                <dd>{item.print_minutes ? `${Number(item.print_minutes)} min per plate` : '—'}</dd>
                <dt>Standard cost</dt>
                <dd>{std ? `${unitCost(std.total_cost)} per unit` : '—'}{std && valid ? ` · about ${money(Number(std.total_cost) * started)} for this order` : ''}</dd>
              </dl>
              <h3 className="small muted" style={{ marginBottom: '0.3rem' }}>Components to issue (bill of material × plates)</h3>
              <div className="table-wrap">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Component</th>
                      <th className="num">Per plate</th>
                      <th className="num">Needed</th>
                      <th className="num">On hand {data.locations.find((l) => l.id === buildLoc) ? `(${shortLocation(data.locations.find((l) => l.id === buildLoc)!)})` : ''}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {bom.map((b) => {
                      const comp = data.itemsById.get(b.component_item_id);
                      const have = stock.at(b.component_item_id, buildLoc)?.qty_on_hand ?? 0;
                      const need = b.qty_per_plate * plates;
                      return (
                        <tr key={b.component_item_id}>
                          <td>{comp?.name ?? '?'}</td>
                          <td className="num">{qty(b.qty_per_plate, comp?.uom)}</td>
                          <td className="num">{valid ? qty(need, comp?.uom) : '—'}</td>
                          <td className={`num ${valid && have < need ? 'bad strong' : ''}`}>{qty(have, comp?.uom)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
              {valid && short.length > 0 && (
                <div className="notice warn spaced">
                  Not enough {short.map((b) => data.itemsById.get(b.component_item_id)?.name).join(', ')} to issue yet. You can still plan the order;
                  MRP counts its components as requirements. <Link to="/mrp">Open MRP</Link>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
