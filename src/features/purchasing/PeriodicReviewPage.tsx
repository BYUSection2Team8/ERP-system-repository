import { useMemo, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { date, dateTime, money, qty } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { localToday } from '../production/productionShared';
import { loadReorderPlan, n, reorderTables, type ReorderRow } from './reorderShared';

interface ReviewStatus {
  last_reviewed_at: string | null;
  last_reviewer: string | null;
  review_interval_days: number;
  next_review_date: string;
}
interface Review {
  id: string;
  reviewed_at: string;
  reviewer: string | null;
  notes: string | null;
  items_below: number;
  po_ids: string[];
}

async function load() {
  const c = db();
  const [plan, status, reviews] = await Promise.all([
    loadReorderPlan(),
    c.from('v_review_status').select('*').single().then(unwrap<ReviewStatus>),
    c.from('inventory_reviews').select('*').order('reviewed_at', { ascending: false }).limit(10).then(unwrap<Review[]>),
  ]);
  return { ...plan, status, reviews };
}

export function PeriodicReviewPage() {
  const { data, error, loading } = useLiveQuery(load, reorderTables);
  const [skip, setSkip] = useState<Set<string>>(new Set());
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; text: ReactNode } | null>(null);
  const today = localToday();

  const rows = useMemo(() => (data?.rows ?? []).filter((r) => r.replenish_by === 'purchase' && Number(r.review_units ?? 0) > 0 && r.supplier_id), [data]);

  if (loading) return <Loading what="periodic review" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const { status } = data;
  const due = status.next_review_date <= today;
  const units = (r: ReorderRow) => (edits[r.item_id] === undefined ? Number(r.review_units) : Number(edits[r.item_id]));
  const chosen = rows.filter((r) => !skip.has(r.item_id) && units(r) > 0);
  const suppliers = new Set(chosen.map((r) => r.supplier_id!));

  async function finish() {
    setBusy(true);
    setResult(null);
    try {
      const ids: string[] = [];
      for (const sid of suppliers) {
        const lines = chosen.filter((r) => r.supplier_id === sid).map((r) => ({ item_id: r.item_id, qty: units(r) }));
        ids.push(await rpc<string>('create_purchase_order', { p: { supplier_id: sid, source: 'review', notes: 'Periodic review', lines } }));
      }
      await rpc('record_inventory_review', { p_notes: notes.trim() || null, p_po_ids: ids });
      setResult({ ok: true, text: <>Review recorded{ids.length ? <> and {ids.length} purchase order{ids.length === 1 ? '' : 's'} sent (<Link to="/purchasing">see them</Link>)</> : ''}. Next review in {status.review_interval_days} days.</> });
      setSkip(new Set());
      setEdits({});
      setNotes('');
    } catch (e) {
      setResult({ ok: false, text: errorMessage(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <PageHeader
        title="Periodic review"
        subtitle={`Every ${status.review_interval_days} days a manager reviews every purchased item and orders it back up to its target level: d̄·(R + L) + z·σ·√(R + L).`}
        actions={<Link className="btn" to="/purchasing/planning">Reorder planning</Link>}
      />
      <div className="stats">
        <Stat label="Next review" value={date(status.next_review_date)} tone={due ? 'warn' : undefined} hint={due ? 'Due now' : `Every ${status.review_interval_days} days`} />
        <Stat label="Last review" value={status.last_reviewed_at ? date(status.last_reviewed_at) : 'Never'} hint={status.last_reviewer ?? undefined} />
        <Stat label="Items below target" value={rows.length} />
        <Stat label="Selected to order" value={chosen.length} hint={`${suppliers.size} supplier(s)`} />
      </div>

      {result && <div className={`notice ${result.ok ? 'ok' : 'error'} spaced`}>{result.text}</div>}

      {rows.length === 0 ? (
        <div className="card muted">Every purchased item is at or above its order-up-to level. You can still record the review.</div>
      ) : (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th></th>
                <th>Item</th>
                <th>Supplier</th>
                <th className="num">Target (order-up-to)</th>
                <th className="num">Position</th>
                <th className="num">Order</th>
                <th className="num">Est. cost</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.item_id}>
                  <td>
                    <input type="checkbox" aria-label={`Order ${r.name}`} checked={!skip.has(r.item_id)}
                      onChange={(e) => {
                        const next = new Set(skip);
                        if (e.target.checked) next.delete(r.item_id); else next.add(r.item_id);
                        setSkip(next);
                      }} />
                  </td>
                  <td>
                    <Link to={`/inventory/item/${r.item_id}`}>{r.name}</Link>
                    <div className="math">{n(r.avg_daily)}×({r.review_interval_days}+{r.lead_days}) + {n(r.z)}×{n(r.sd_daily)}×√{r.review_interval_days + r.lead_days}</div>
                  </td>
                  <td>{r.supplier_name}</td>
                  <td className="num">{qty(r.order_up_to, r.uom)}</td>
                  <td className="num">{qty(r.position, r.uom)}</td>
                  <td className="num">
                    <input className="qty-input" type="number" min={0} step={1} value={edits[r.item_id] ?? String(r.review_units)}
                      onChange={(e) => setEdits({ ...edits, [r.item_id]: e.target.value })} /> <span className="muted small">{r.purchase_uom}</span>
                  </td>
                  <td className="num">{money(units(r) * Number(r.purchase_unit_cost ?? 0))}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="form card spaced">
        <label>
          Review notes
          <input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="e.g. Skipped magnets: big order arriving Friday" />
        </label>
        <div className="page-actions">
          <button className="btn primary" disabled={busy} onClick={finish}>
            {busy ? 'Saving…' : chosen.length ? `Send ${suppliers.size} PO${suppliers.size === 1 ? '' : 's'} and record review` : 'Record review (nothing to order)'}
          </button>
        </div>
      </div>

      <h2>Review history</h2>
      {data.reviews.length === 0 ? (
        <p className="muted">No reviews recorded yet.</p>
      ) : (
        <ul className="activity">
          {data.reviews.map((r) => (
            <li key={r.id}>
              <span className="muted small">{dateTime(r.reviewed_at)} · {r.reviewer ?? 'staff'}</span>
              <span>{r.items_below} item(s) below target · {r.po_ids.length} PO(s){r.notes ? ` · ${r.notes}` : ''}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
