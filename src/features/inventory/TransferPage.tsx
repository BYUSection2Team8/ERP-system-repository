import { useEffect, useState, type FormEvent } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import { qty } from '../../lib/format';
import type { Item } from '../../lib/types';
import { ScanItemInput } from '../barcodes/ScanItemInput';
import { useInventoryData } from './useInventoryData';

interface Line {
  item: Item;
  qty: string;
}

export function TransferPage() {
  const { data, error, loading } = useInventoryData();
  const [params] = useSearchParams();
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [lines, setLines] = useState<Line[]>([]);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);

  // Defaults: Fulfillment Center -> Campus Counter (restocking the counter).
  useEffect(() => {
    if (!data || from) return;
    setFrom(data.locations.find((l) => l.code === 'FULFILLMENT')?.id ?? '');
    setTo(data.locations.find((l) => l.code === 'CAMPUS')?.id ?? '');
    const pre = data.items.find((i) => i.id === params.get('item'));
    if (pre) setLines([{ item: pre, qty: '1' }]);
  }, [data, from, params]);

  if (loading) return <Loading />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const { items, locations, at } = data;

  function addItem(item: Item) {
    setResult(null);
    setLines((ls) => {
      const existing = ls.find((l) => l.item.id === item.id);
      if (existing) {
        // Scanning the same item again adds one more.
        return ls.map((l) => (l.item.id === item.id ? { ...l, qty: String(Number(l.qty || 0) + 1) } : l));
      }
      return [...ls, { item, qty: '1' }];
    });
  }

  const problems = lines
    .map((l) => {
      const n = Number(l.qty);
      const have = Number(at(l.item.id, from)?.qty_on_hand ?? 0);
      if (!(n > 0)) return `${l.item.name}: enter a quantity above zero.`;
      if (l.item.uom === 'ea' && !Number.isInteger(n)) return `${l.item.name}: whole numbers only.`;
      if (n > have) return `${l.item.name}: only ${qty(have, l.item.uom)} at the source location.`;
      return null;
    })
    .filter((p): p is string => p !== null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (from === to) return setResult({ ok: false, text: 'Choose two different locations.' });
    setBusy(true);
    setResult(null);
    try {
      await rpc('transfer_inventory', {
        p_from: from,
        p_to: to,
        p_lines: lines.map((l) => ({ item_id: l.item.id, qty: Number(l.qty) })),
        p_note: note || null,
      });
      const n = lines.length;
      setLines([]);
      setNote('');
      setResult({ ok: true, text: `Transferred ${n} item${n === 1 ? '' : 's'}.` });
    } catch (err) {
      setResult({ ok: false, text: errorMessage(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <PageHeader title="Transfer stock" subtitle="Move items between locations. Cost moves with the goods." />
      <form className="card form" onSubmit={submit}>
        <div className="form-row">
          <label>
            From
            <select value={from} onChange={(e) => setFrom(e.target.value)}>
              {locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
            </select>
          </label>
          <button
            type="button"
            className="btn swap"
            title="Swap"
            onClick={() => {
              setFrom(to);
              setTo(from);
            }}
          >
            ⇄
          </button>
          <label>
            To
            <select value={to} onChange={(e) => setTo(e.target.value)}>
              {locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
            </select>
          </label>
        </div>

        <label>
          Add items
          <ScanItemInput items={items} onPick={addItem} autoFocus />
        </label>

        {lines.length > 0 && (
          <table className="table">
            <thead>
              <tr><th>Item</th><th className="num">At source</th><th className="num">Qty to move</th><th /></tr>
            </thead>
            <tbody>
              {lines.map((l) => (
                <tr key={l.item.id}>
                  <td>{l.item.name}<div className="muted small">{l.item.sku}</div></td>
                  <td className="num">{qty(at(l.item.id, from)?.qty_on_hand ?? 0, l.item.uom)}</td>
                  <td className="num">
                    <input
                      className="qty-input"
                      type="number"
                      min="0"
                      step={l.item.uom === 'g' ? 'any' : 1}
                      value={l.qty}
                      onChange={(e) =>
                        setLines((ls) => ls.map((x) => (x.item.id === l.item.id ? { ...x, qty: e.target.value } : x)))
                      }
                      aria-label={`Quantity of ${l.item.name}`}
                    />
                    {l.item.uom === 'g' && <span className="muted small"> g</span>}
                  </td>
                  <td>
                    <button type="button" className="btn link" onClick={() => setLines((ls) => ls.filter((x) => x.item.id !== l.item.id))}>
                      Remove
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        <label>
          Note (optional)
          <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Restock counter for Friday" />
        </label>

        {problems.length > 0 && <div className="notice warn">{problems.map((p) => <div key={p}>{p}</div>)}</div>}
        {result && <div className={`notice ${result.ok ? 'ok' : 'error'}`}>{result.text} {result.ok && <Link to="/inventory">View inventory</Link>}</div>}

        <div>
          <button className="btn primary" disabled={busy || lines.length === 0 || problems.length > 0 || from === to}>
            {busy ? 'Transferring…' : 'Transfer'}
          </button>
        </div>
      </form>
    </div>
  );
}
