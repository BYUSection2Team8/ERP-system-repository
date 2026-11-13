const money2 = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const money4 = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 4,
});
const num = new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 });

export function money(v: number | string | null | undefined): string {
  return v === null || v === undefined ? '—' : money2.format(Number(v));
}

/** Unit costs can be fractions of a cent (filament is priced per gram). */
export function unitCost(v: number | string | null | undefined): string {
  return v === null || v === undefined ? '—' : money4.format(Number(v));
}

export function qty(v: number | string | null | undefined, uom: 'ea' | 'g' = 'ea'): string {
  if (v === null || v === undefined) return '—';
  const n = Number(v);
  return uom === 'g' ? `${num.format(n)} g` : num.format(n);
}

/** Filament grams as spools, e.g. "7,880 g (8.0 spools)". */
export function grams(v: number | string, spoolGrams: number): string {
  const n = Number(v);
  return `${num.format(n)} g (${(n / spoolGrams).toFixed(1)} spools)`;
}

export function date(v: string | null | undefined): string {
  if (!v) return '—';
  // Plain dates ("2026-11-12") are business dates: do not shift by time zone.
  const d = /^\d{4}-\d{2}-\d{2}$/.test(v) ? new Date(`${v}T12:00:00`) : new Date(v);
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

export function dateTime(v: string | null | undefined): string {
  if (!v) return '—';
  return new Date(v).toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
}

export const sourceLabels: Record<string, string> = {
  opening: 'Opening balance',
  po_receipt: 'PO receipt',
  sale: 'Sale',
  sale_return: 'Customer return',
  transfer_out: 'Transfer out',
  transfer_in: 'Transfer in',
  adjustment: 'Adjustment',
  production_issue: 'Issued to production',
  production_output: 'Production output',
};

/**
 * Grams with the item's own purchase pack, e.g. "7,880 g (8.0 spools)" for
 * filament or "250 g (12.5 tubes)" for glue. No pack (or a 1 g pack): grams only.
 */
export function gramsInPacks(v: number | string, pack?: { uom: string; size: number }): string {
  const n = Number(v);
  if (!pack || !(pack.size > 1)) return `${num.format(n)} g`;
  const count = n / pack.size;
  return `${num.format(n)} g (${count.toFixed(1)} ${pack.uom}${Math.abs(count - 1) < 0.05 ? '' : 's'})`;
}
