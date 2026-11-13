import { useState } from 'react';
import { errorMessage, rpc } from '../../lib/db';
import type { PoStatus } from '../../lib/types';

// Shared pieces for the purchasing and supplier screens. Scorecards, reorder
// points and EOQ are computed by database views (010_purchasing_planning.sql).

export const poStatusLabels: Record<PoStatus, string> = {
  draft: 'Draft',
  sent: 'Order sent',
  partial: 'Partly received',
  received: 'Received',
  closed: 'Closed',
  cancelled: 'Cancelled',
};

export function PoStatusBadge({ status }: { status: PoStatus }) {
  const tone = status === 'sent' || status === 'partial' || status === 'draft' ? 'warn' : status === 'cancelled' ? '' : 'ok';
  return <span className={`badge status ${tone}`}>{poStatusLabels[status]}</span>;
}

export const poSourceLabels: Record<string, string> = {
  manual: 'Manual',
  mrp: 'MRP',
  reorder: 'Reorder point',
  review: 'Periodic review',
};

/** Payment terms a supplier can have; terms_days = 0 means paid at purchase. */
export const termsOptions: { label: string; days: number }[] = [
  { label: 'Paid at purchase', days: 0 },
  { label: 'Net 15', days: 15 },
  { label: 'Net 30', days: 30 },
  { label: 'Net 45', days: 45 },
  { label: 'Net 60', days: 60 },
];

export function RatingBadge({ rating }: { rating: string | null }) {
  const cls = rating === 'Keep' ? 'keep' : rating === 'Watch' ? 'watch' : rating === 'Replace' ? 'replace' : '';
  return <span className={`rating ${cls}`}>{rating ?? '—'}</span>;
}

export function ScoreBar({ value }: { value: number | null }) {
  if (value === null || value === undefined) return null;
  return (
    <div className="score-bar" aria-hidden>
      <span style={{ width: `${Math.max(0, Math.min(100, Number(value) * 100))}%` }} />
    </div>
  );
}

export function pct(v: number | string | null | undefined, digits = 0): string {
  if (v === null || v === undefined) return '—';
  return `${(Number(v) * 100).toFixed(digits)}%`;
}

export interface PlanLine {
  item_id: string;
  qty: number;
  need_date?: string | null;
}

/** Create and send one purchase order per supplier; returns the new PO ids. */
export function useCreatePos() {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  async function create(supplierId: string, lines: PlanLine[], source: 'reorder' | 'review' | 'mrp' | 'manual', notes?: string) {
    setBusy(supplierId);
    setError(null);
    try {
      return await rpc<string>('create_purchase_order', { p: { supplier_id: supplierId, source, notes, lines } });
    } catch (e) {
      setError(errorMessage(e));
      return null;
    } finally {
      setBusy(null);
    }
  }
  return { create, busy, error };
}
