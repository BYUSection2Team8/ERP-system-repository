import { useEffect, useState, type FormEvent } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import { money, qty, unitCost } from '../../lib/format';
import type { Item } from '../../lib/types';
import { ScanItemInput } from '../barcodes/ScanItemInput';
import { useInventoryData } from './useInventoryData';

type Mode = 'count' | 'adjust';

export function AdjustPage() {
  const { data, error, loading } = useInventoryData();
  const [params] = useSearchParams();
  const [mode, setMode] = useState<Mode>('count');
  const [item, setItem] = useState<Item | null>(null);
  const [location, setLocation] = useState('');
  const [amount, setAmount] = useState('');
  const [direction, setDirection] = useState<'remove' | 'add'>('remove');
  const [reason, setReason] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);

  useEffect(() => {
    if (!data || location) return;
    setLocation(data.locations.find((l) => l.code === 'FULFILLMENT')?.id ?? data.locations[0]?.id ?? '');
    const pre = data.items.find((i) => i.id === params.get('item'));
    if (pre) setItem(pre);
  }, [data, location, params]);

  if (loading) return <Loading />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const { items, locations, reasons, valuation, at } = data;
  const adjustReasons = reasons.filter((r) => r.category === 'adjustment');
  const effectiveReason = reason || (mode === 'count' ? 'ADJ_CYCLE_COUNT' : adjustReasons.find((r) => r.code !== 'ADJ_CYCLE_COUNT')?.code ?? '');

  const onHand = item ? Number(at(item.id, location)?.qty_on_hand ?? 0) : 0;
  const n = Number(amount);
  const delta = amount === '' || Number.isNaN(n) ? null : mode === 'count' ? n - onHand : direction === 'remove' ? -n : n;
  const avgCost = item ? Number(valuation.get(item.id)?.avg_unit_cost ?? 0) : 0;

  let problem: string | null = null;
  if (item && amount !== '') {
    if (Number.isNaN(n) || n < 0) problem = 'Enter a number zero or above.';
    else if (item.uom === 'ea' && !Number.isInteger(n)) problem = 'Whole numbers only for this item.';
    else if (mode === 'adjust' && n === 0) problem = 'Enter how many to add or remove.';
    else if (delta !== null && onHand + delta < 0) problem = `Only ${qty(onHand, item.uom)} on hand here.`;
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!item || delta === null) return;
    setBusy(true);
    setResult(null);
    try {
      if (mode === 'count') {
        const id = await rpc<string | null>('count_inventory', {
          p_item: item.id,
          p_location: location,
          p_counted: n,
          p_reason: effectiveReason,
          p_note: note || null,
        });
        setResult({
          ok: true,
          text: id
            ? `Count posted: ${item.name} ${delta! > 0 ? '+' : ''}${qty(delta, item.uom)}.`
            : `Count matches the system (${qty(n, item.uom)}). Nothing to post.`,
        });
      } else {
        await rpc('adjust_inventory', {
          p_item: item.id,
          p_location: location,
          p_qty_delta: delta,
          p_reason: effectiveReason,
          p_note: note || null,
        });
        setResult({ ok: true, text: `Adjusted ${item.name} by ${delta > 0 ? '+' : ''}${qty(delta, item.uom)}.` });
      }
      setAmount('');
      setNote('');
    } catch (err) {
      setResult({ ok: false, text: errorMessage(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <PageHeader
        title="Adjust & count"
        subtitle="Cycle counts and corrections. Losses post to Inventory adjustments on the P&L."
      />
      <div className="tabs no-print">
        <button className={mode === 'count' ? 'active' : ''} onClick={() => { setMode('count'); setReason(''); setResult(null); }}>
          Cycle count
        </button>
        <button className={mode === 'adjust' ? 'active' : ''} onClick={() => { setMode('adjust'); setReason(''); setResult(null); }}>
          Adjust (damaged, lost, found…)
        </button>
      </div>

      <form className="card form" onSubmit={submit}>
        <div className="form-row">
          <label className="grow">
            Item
            <ScanItemInput items={items} onPick={(i) => { setItem(i); setResult(null); }} autoFocus />
          </label>
          <label>
            Location
            <select value={location} onChange={(e) => setLocation(e.target.value)}>
              {locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
            </select>
          </label>
        </div>

        {item && (
          <div className="picked">
            <div>
              <strong>{item.name}</strong> <span className="muted small">{item.sku}</span>
            </div>
            <div className="muted small">
              System on hand here: <strong>{qty(onHand, item.uom)}</strong> · Avg cost {unitCost(avgCost)}
              {item.uom === 'g' ? '/g' : ''}
            </div>
          </div>
        )}

        <div className="form-row">
          {mode === 'adjust' && (
            <label>
              Direction
              <select value={direction} onChange={(e) => setDirection(e.target.value as 'remove' | 'add')}>
                <option value="remove">Remove from stock</option>
                <option value="add">Add to stock</option>
              </select>
            </label>
          )}
          <label>
            {mode === 'count' ? 'Counted quantity' : 'Quantity'} {item?.uom === 'g' ? '(grams)' : ''}
            <input type="number" min="0" step={item?.uom === 'g' ? 'any' : 1} value={amount} onChange={(e) => setAmount(e.target.value)} disabled={!item} />
          </label>
          <label>
            Reason code
            <select value={effectiveReason} onChange={(e) => setReason(e.target.value)}>
              {adjustReasons.map((r) => <option key={r.code} value={r.code}>{r.description}</option>)}
            </select>
          </label>
        </div>

        {item && delta !== null && !problem && (
          <div className="notice">
            {delta === 0
              ? 'No difference from the system quantity.'
              : <>Change: <strong>{delta > 0 ? '+' : ''}{qty(delta, item.uom)}</strong> → new on hand {qty(onHand + delta, item.uom)}.
                  {' '}Value {delta < 0 ? 'written off' : 'added'}: <strong>{money(Math.abs(delta) * avgCost)}</strong> at weighted-average cost.</>}
          </div>
        )}

        <label>
          Note (optional)
          <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Dropped two on the floor" />
        </label>

        {problem && <div className="notice warn">{problem}</div>}
        {result && <div className={`notice ${result.ok ? 'ok' : 'error'}`}>{result.text} {result.ok && item && <Link to={`/inventory/item/${item.id}`}>View item</Link>}</div>}

        <div>
          <button className="btn primary" disabled={busy || !item || delta === null || !!problem || (mode === 'adjust' && delta === 0)}>
            {busy ? 'Posting…' : mode === 'count' ? 'Post count' : 'Post adjustment'}
          </button>
        </div>
      </form>
    </div>
  );
}
