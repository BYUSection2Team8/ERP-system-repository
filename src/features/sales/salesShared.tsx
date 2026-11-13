import { useEffect, useRef, useState } from 'react';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { money, qty as fmtQty } from '../../lib/format';
import type { Customer, DiscountType, Item, Quote, ReasonCode, SoStatus } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';

// Shared pieces for the POS and Sales Order screens.
// Prices, discounts, shipping and tax are NEVER calculated here: the screens
// ask the database for a quote (quote_sales_order), which uses the same SQL
// as create_sales_order / pos_sale, so the preview always matches what is saved.

export const statusLabels: Record<SoStatus, string> = {
  placed: 'Order placed',
  fulfilled: 'Fulfilled',
  closed: 'Closed',
  cancelled: 'Cancelled',
};

export function StatusBadge({ status, backordered = false }: { status: SoStatus; backordered?: boolean }) {
  const tone = status === 'placed' ? 'warn' : status === 'cancelled' ? '' : 'ok';
  return (
    <>
      <span className={`badge status ${tone} ${status}`}>{statusLabels[status]}</span>
      {backordered && <span className="badge bad">Backordered</span>}
    </>
  );
}

export const channelLabels: Record<string, string> = {
  pos: 'Point of sale',
  online: 'Online',
  phone: 'Phone',
  portal: 'Customer portal',
};

export const methodLabels: Record<string, string> = {
  ship: 'Ship',
  pickup: 'Pickup',
  counter: 'Counter sale',
};

export const paymentLabels: Record<string, string> = {
  cash: 'Cash',
  card: 'Card',
  account: 'On account',
  exchange: 'Exchange',
};

export function pct(v: number | string): string {
  return `${Number((Number(v) * 100).toFixed(2))}%`;
}

// ---------------------------------------------------------------------------
// Reference data used by both screens (live).
// ---------------------------------------------------------------------------
export interface SalesSettings {
  byuPct: number;
  businessPct: number;
  businessMinUnits: number;
  maxManualPct: number;
  taxRate: number;
  taxState: string;
  shippingFee: number;
  returnDays: number;
  companyName: string;
}

export interface SalesRefData {
  customers: Customer[];
  discountReasons: ReasonCode[];
  settings: SalesSettings;
}

async function loadRef(): Promise<SalesRefData> {
  const c = db();
  const [customers, reasons, settings] = await Promise.all([
    c.from('customers').select('*').eq('is_active', true).order('name').then(unwrap<Customer[]>),
    c.from('reason_codes').select('*').eq('category', 'discount').eq('is_active', true).order('sort_order').then(unwrap<ReasonCode[]>),
    c.from('settings').select('key, value').then(unwrap<{ key: string; value: string }[]>),
  ]);
  const s = new Map(settings.map((x) => [x.key, x.value]));
  const n = (k: string, d: number) => Number(s.get(k) ?? d);
  return {
    customers,
    discountReasons: reasons,
    settings: {
      byuPct: n('byu_discount_pct', 0),
      businessPct: n('business_discount_pct', 0),
      businessMinUnits: n('business_discount_min_units', 0),
      maxManualPct: n('max_manual_discount_pct', 0),
      taxRate: n('sales_tax_rate', 0),
      taxState: s.get('tax_state') ?? 'UT',
      shippingFee: n('flat_shipping_fee', 0),
      returnDays: n('return_window_days', 30),
      companyName: s.get('company_name') ?? 'Poulson Prints',
    },
  };
}

export function useSalesRefData() {
  return useLiveQuery(loadRef, ['customers', 'reason_codes', 'settings']);
}

// ---------------------------------------------------------------------------
// Live price preview from the database.
// ---------------------------------------------------------------------------
/** Re-prices `payload` (debounced) whenever it changes. null = nothing to price. */
export function useQuote(payload: Record<string, unknown> | null) {
  const [quote, setQuote] = useState<Quote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pricing, setPricing] = useState(false);
  const seq = useRef(0);
  const key = payload ? JSON.stringify(payload) : '';

  useEffect(() => {
    const mine = ++seq.current;
    if (!key) {
      setQuote(null);
      setError(null);
      setPricing(false);
      return;
    }
    setPricing(true);
    const t = window.setTimeout(async () => {
      try {
        const q = await rpc<Quote>('quote_sales_order', { p: JSON.parse(key) });
        if (mine !== seq.current) return;
        setQuote(q);
        setError(null);
      } catch (e) {
        if (mine !== seq.current) return;
        setQuote(null);
        setError(errorMessage(e));
      } finally {
        if (mine === seq.current) setPricing(false);
      }
    }, 250);
    return () => window.clearTimeout(t);
  }, [key]);

  return { quote, error, pricing };
}

// ---------------------------------------------------------------------------
// Cart / order lines
// ---------------------------------------------------------------------------
export interface CartLine {
  item: Item;
  qty: string;
}

/** Add an item (or one more of it, when scanned again). */
export function addToCart(lines: CartLine[], item: Item): CartLine[] {
  if (lines.some((l) => l.item.id === item.id)) {
    return lines.map((l) => (l.item.id === item.id ? { ...l, qty: String(Number(l.qty || 0) + 1) } : l));
  }
  return [...lines, { item, qty: '1' }];
}

export function cartProblems(lines: CartLine[]): string[] {
  return lines
    .map((l) => {
      const n = Number(l.qty);
      if (!(n > 0)) return `${l.item.name}: enter a quantity above zero.`;
      if (l.item.uom === 'ea' && !Number.isInteger(n)) return `${l.item.name}: whole numbers only.`;
      return null;
    })
    .filter((p): p is string => p !== null);
}

/**
 * Editable lines with list price (from the item) and line total (from the
 * database quote). `available` shows stock at the selling location.
 */
export function CartTable({
  lines,
  setLines,
  quote,
  available,
  shortLabel,
}: {
  lines: CartLine[];
  setLines: (f: (ls: CartLine[]) => CartLine[]) => void;
  quote: Quote | null;
  available: (itemId: string) => number;
  shortLabel: string;
}) {
  if (lines.length === 0) return <p className="muted cart-empty">No items yet. Scan a barcode or search above.</p>;
  return (
    <div className="table-wrap">
      <table className="table cart">
        <thead>
          <tr>
            <th>Item</th>
            <th className="num">Available</th>
            <th className="num">Qty</th>
            <th className="num">Price</th>
            <th className="num">Line total</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => {
            const have = available(l.item.id);
            const short = Number(l.qty) > have;
            const ql = quote?.lines.find((x) => x.item_id === l.item.id);
            return (
              <tr key={l.item.id}>
                <td>
                  {l.item.name}
                  <div className="muted small">{l.item.sku}</div>
                  {short && <div className="small bad">{shortLabel}</div>}
                </td>
                <td className={`num ${short ? 'bad' : ''}`}>{fmtQty(have, l.item.uom)}</td>
                <td className="num">
                  <div className="qty-stepper">
                    <button
                      type="button"
                      className="btn"
                      aria-label={`One fewer ${l.item.name}`}
                      onClick={() => setLines((ls) => ls.map((x) => (x.item.id === l.item.id ? { ...x, qty: String(Math.max(1, Number(x.qty || 1) - 1)) } : x)))}
                    >
                      −
                    </button>
                    <input
                      className="qty-input"
                      type="number"
                      min="1"
                      step={l.item.uom === 'g' ? 'any' : 1}
                      value={l.qty}
                      onChange={(e) => setLines((ls) => ls.map((x) => (x.item.id === l.item.id ? { ...x, qty: e.target.value } : x)))}
                      aria-label={`Quantity of ${l.item.name}`}
                    />
                    <button
                      type="button"
                      className="btn"
                      aria-label={`One more ${l.item.name}`}
                      onClick={() => setLines((ls) => addToCart(ls, l.item))}
                    >
                      +
                    </button>
                  </div>
                </td>
                <td className="num">{money(l.item.price)}</td>
                <td className="num">{ql ? money(ql.line_total) : '…'}</td>
                <td>
                  <button type="button" className="btn link" onClick={() => setLines((ls) => ls.filter((x) => x.item.id !== l.item.id))}>
                    Remove
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Discount picker (one discount per order)
// ---------------------------------------------------------------------------
export interface DiscountChoice {
  type: DiscountType;
  pct: string; // manual only, in percent (e.g. "15")
  reason: string; // manual only
}

export const noDiscount: DiscountChoice = { type: 'none', pct: '', reason: '' };

export function discountPayload(d: DiscountChoice): Record<string, unknown> {
  if (d.type !== 'manual') return { discount_type: d.type };
  return {
    discount_type: 'manual',
    discount_pct: d.pct === '' ? null : Number(d.pct) / 100,
    discount_reason: d.reason || null,
  };
}

export function DiscountPicker({
  value,
  onChange,
  settings,
  reasons,
  units,
  isByu,
}: {
  value: DiscountChoice;
  onChange: (d: DiscountChoice) => void;
  settings: SalesSettings;
  reasons: ReasonCode[];
  units: number;
  isByu: boolean;
}) {
  const businessOk = units >= settings.businessMinUnits;
  return (
    <fieldset className="discount">
      <legend>Discount (one per order)</legend>
      <div className="choice-row">
        <label className="check">
          <input type="radio" checked={value.type === 'none'} onChange={() => onChange({ ...value, type: 'none' })} /> None
        </label>
        <label className="check">
          <input type="radio" checked={value.type === 'byu'} onChange={() => onChange({ ...value, type: 'byu' })} />
          BYU student {pct(settings.byuPct)}
          {isByu && <span className="badge ok">customer is BYU</span>}
        </label>
        <label className="check" title={businessOk ? '' : `Needs ${settings.businessMinUnits}+ units`}>
          <input
            type="radio"
            disabled={!businessOk}
            checked={value.type === 'business'}
            onChange={() => onChange({ ...value, type: 'business' })}
          />
          Business {pct(settings.businessPct)} on {settings.businessMinUnits}+ units
        </label>
        <label className="check">
          <input type="radio" checked={value.type === 'manual'} onChange={() => onChange({ ...value, type: 'manual' })} /> Manual
        </label>
      </div>
      {value.type === 'manual' && (
        <div className="form-row">
          <label>
            Percent off (max {pct(settings.maxManualPct)})
            <input
              type="number"
              min="0"
              max={settings.maxManualPct * 100}
              step="0.5"
              value={value.pct}
              onChange={(e) => onChange({ ...value, pct: e.target.value })}
              placeholder="e.g. 15"
            />
          </label>
          <label className="grow">
            Reason (required)
            <select value={value.reason} onChange={(e) => onChange({ ...value, reason: e.target.value })}>
              <option value="">Choose a reason…</option>
              {reasons.map((r) => (
                <option key={r.code} value={r.code}>{r.description}</option>
              ))}
            </select>
          </label>
        </div>
      )}
    </fieldset>
  );
}

// ---------------------------------------------------------------------------
// Totals (from the database quote or the saved order)
// ---------------------------------------------------------------------------
export interface Totals {
  subtotal: number;
  discount_type: DiscountType;
  discount_pct: number;
  discount_amount: number;
  shipping_amount: number;
  tax_rate: number;
  tax_amount: number;
  total: number;
  ship_state?: string | null;
}

export const discountNames: Record<DiscountType, string> = {
  none: 'Discount',
  byu: 'BYU student discount',
  business: 'Business bulk discount',
  manual: 'Manual discount',
};

export function TotalsTable({ t, reasonText }: { t: Totals; reasonText?: string | null }) {
  return (
    <table className="totals">
      <tbody>
        <tr>
          <td>Subtotal</td>
          <td className="num">{money(t.subtotal)}</td>
        </tr>
        {Number(t.discount_amount) > 0 && (
          <tr>
            <td>
              {discountNames[t.discount_type]} ({pct(t.discount_pct)})
              {reasonText && <div className="muted small">{reasonText}</div>}
            </td>
            <td className="num">−{money(t.discount_amount)}</td>
          </tr>
        )}
        {Number(t.shipping_amount) > 0 && (
          <tr>
            <td>Shipping</td>
            <td className="num">{money(t.shipping_amount)}</td>
          </tr>
        )}
        <tr>
          <td>
            Sales tax ({pct(t.tax_rate)})
            {Number(t.tax_rate) === 0 && t.ship_state && <div className="muted small">No tax: ships to {t.ship_state}</div>}
          </td>
          <td className="num">{money(t.tax_amount)}</td>
        </tr>
        <tr className="grand">
          <td>Total</td>
          <td className="num">{money(t.total)}</td>
        </tr>
      </tbody>
    </table>
  );
}

export function QuotePanel({
  quote,
  error,
  pricing,
  reasons,
}: {
  quote: Quote | null;
  error: string | null;
  pricing: boolean;
  reasons: ReasonCode[];
}) {
  if (error) return <div className="notice error">{error}</div>;
  if (!quote) return <p className="muted">{pricing ? 'Pricing…' : 'Add items to see the total.'}</p>;
  const reason = reasons.find((r) => r.code === quote.discount_reason)?.description;
  return (
    <div className={pricing ? 'repricing' : ''}>
      <TotalsTable t={quote} reasonText={reason} />
      {quote.shipping && (
        <p className="muted small" style={{ margin: '0.25rem 0' }}>
          Shipping: zone {quote.shipping.zone} from Stansbury Park, {Number(quote.shipping.weight_oz)} oz parcel → postage {money(quote.shipping.postage)} + handling {money(quote.shipping.handling)}
        </p>
      )}
      <p className="muted small">Priced by the database from item prices and settings.</p>
    </div>
  );
}
