import { useEffect, useRef, useState } from 'react';
import { ShowMath } from '../../app/ShowMath';
import { errorMessage, rpc } from '../../lib/db';
import { date, dateTime, money, unitCost } from '../../lib/format';

// Custom quote calculator (wow factor #4). The database prices the job
// (quote_custom_print) from settings, weighted-average filament cost and the
// real recent scrap rate; the screen only shows the result and its math.

export interface CustomQuote {
  name: string;
  print_hours: number;
  grams: number;
  assembly_minutes: number;
  qty: number;
  color: string;
  fulfillment_method: 'pickup' | 'ship';
  ship_state: string | null;
  inputs: {
    filament_cost_per_g: number;
    machine_rate_per_hour: number;
    labor_rate: number;
    setup_cleanup_minutes: number;
    packaging_per_order: number;
    markup: number;
    minimum_price: number;
    failure_rate: number;
    failure_window_days: number;
    units_started: number;
    units_scrapped: number;
    printers: number;
    queue_hours: number;
    tax_rate: number;
  };
  cost: { filament: number; machine: number; labor: number; packaging: number; failure_allowance: number; unit_cost: number };
  unit_price: number;
  minimum_applied: boolean;
  subtotal: number;
  shipping_amount: number;
  tax_amount: number;
  total: number;
  ready_at: string;
  ready_date: string;
  est_delivery_date: string | null;
}

export interface QuoteForm {
  name: string;
  description: string;
  print_hours: string;
  grams: string;
  color: string;
  assembly_minutes: string;
  qty: string;
  fulfillment_method: 'pickup' | 'ship';
  ship_state: string;
  notes: string;
}

export const emptyQuoteForm: QuoteForm = {
  name: '',
  description: '',
  print_hours: '',
  grams: '',
  color: 'Blue',
  assembly_minutes: '0',
  qty: '1',
  fulfillment_method: 'pickup',
  ship_state: '',
  notes: '',
};

export const quoteColors = ['Red', 'White', 'Blue', 'Black'];

export function quotePayload(f: QuoteForm): Record<string, unknown> | null {
  if (!f.name.trim() || !f.print_hours.trim() || !f.grams.trim()) return null;
  return {
    name: f.name.trim(),
    description: f.description.trim() || null,
    print_hours: f.print_hours.trim(),
    grams: f.grams.trim(),
    color: f.color,
    assembly_minutes: f.assembly_minutes.trim() || '0',
    qty: f.qty.trim() || '1',
    fulfillment_method: f.fulfillment_method,
    ship_state: f.fulfillment_method === 'ship' ? f.ship_state.trim() : null,
    notes: f.notes.trim() || null,
  };
}

export function useCustomQuote(payload: Record<string, unknown> | null) {
  const [quote, setQuote] = useState<CustomQuote | null>(null);
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
        const q = await rpc<CustomQuote>('quote_custom_print', { p: JSON.parse(key) });
        if (mine === seq.current) {
          setQuote(q);
          setError(null);
        }
      } catch (e) {
        if (mine === seq.current) {
          setQuote(null);
          setError(errorMessage(e));
        }
      } finally {
        if (mine === seq.current) setPricing(false);
      }
    }, 350);
    return () => window.clearTimeout(t);
  }, [key]);
  return { quote, error, pricing };
}

export function QuoteFields({ f, set, allowShip }: { f: QuoteForm; set: (f: QuoteForm) => void; allowShip: boolean }) {
  const up = (k: keyof QuoteForm) => (e: { target: { value: string } }) => set({ ...f, [k]: e.target.value });
  return (
    <>
      <div className="form-row">
        <label className="grow">
          Design name
          <input value={f.name} maxLength={40} onChange={up('name')} placeholder="e.g. Rocket desk lamp" />
        </label>
        <label>
          Color
          <select value={f.color} onChange={up('color')}>
            {quoteColors.map((c) => <option key={c}>{c}</option>)}
          </select>
        </label>
      </div>
      <label>
        Description (optional)
        <input value={f.description} maxLength={300} onChange={up('description')} placeholder="Size, link to the model, anything we should know" />
      </label>
      <div className="form-row">
        <label>
          Print time (hours)
          <input type="number" min="0.1" max="48" step="0.1" value={f.print_hours} onChange={up('print_hours')} placeholder="from the slicer" />
        </label>
        <label>
          Filament (grams)
          <input type="number" min="1" max="2000" step="1" value={f.grams} onChange={up('grams')} placeholder="from the slicer" />
        </label>
        <label>
          Assembly (minutes)
          <input type="number" min="0" max="240" step="1" value={f.assembly_minutes} onChange={up('assembly_minutes')} />
        </label>
        <label>
          Quantity
          <input type="number" min="1" max="50" step="1" value={f.qty} onChange={up('qty')} />
        </label>
      </div>
      {allowShip && (
        <div className="form-row">
          <label className="check"><input type="radio" checked={f.fulfillment_method === 'pickup'} onChange={() => set({ ...f, fulfillment_method: 'pickup' })} /> BYU campus pickup</label>
          <label className="check"><input type="radio" checked={f.fulfillment_method === 'ship'} onChange={() => set({ ...f, fulfillment_method: 'ship' })} /> Ship</label>
          {f.fulfillment_method === 'ship' && (
            <label>
              Ship-to state
              <input className="state-input" maxLength={2} value={f.ship_state} onChange={up('ship_state')} placeholder="UT" />
            </label>
          )}
        </div>
      )}
    </>
  );
}

/** Price, ready date and the full calculation. */
export function QuoteResult({ q, pricing }: { q: CustomQuote; pricing: boolean }) {
  const i = q.inputs;
  const c = q.cost;
  return (
    <div className={pricing ? 'repricing' : ''}>
      <div className="quote-price">
        <span className="muted small">Price each</span>
        <strong>{money(q.unit_price)}</strong>
        {q.minimum_applied && <span className="muted small">minimum price</span>}
      </div>
      <table className="totals">
        <tbody>
          <tr><td>{q.qty} × {money(q.unit_price)}</td><td className="num">{money(q.subtotal)}</td></tr>
          {Number(q.shipping_amount) > 0 && <tr><td>Shipping</td><td className="num">{money(q.shipping_amount)}</td></tr>}
          <tr><td>Sales tax ({(Number(i.tax_rate) * 100).toFixed(2)}%){Number(i.tax_rate) === 0 && q.ship_state ? <div className="muted small">No tax: ships to {q.ship_state}</div> : null}</td><td className="num">{money(q.tax_amount)}</td></tr>
          <tr className="grand"><td>Total</td><td className="num">{money(q.total)}</td></tr>
        </tbody>
      </table>
      <p className="small" style={{ margin: '0.5rem 0' }}>
        {q.fulfillment_method === 'ship'
          ? <>Printed by about <strong>{dateTime(q.ready_at)}</strong>; estimated delivery <strong>{date(q.est_delivery_date)}</strong>.</>
          : <>Ready for pickup about <strong>{dateTime(q.ready_at)}</strong>.</>}
      </p>
      <ShowMath
        formula="price each = max(minimum, (filament + machine + labor + packaging + failure allowance) × markup)"
        rows={[
          { label: `Filament: ${Number(q.grams)} g × ${unitCost(i.filament_cost_per_g)}/g`, value: unitCost(c.filament), source: `weighted-average cost of ${q.color} PLA` },
          { label: `Machine: ${Number(q.print_hours)} h × ${unitCost(i.machine_rate_per_hour)}/h`, value: unitCost(c.machine), source: 'machine rate from Settings (depreciation + power + maintenance)' },
          { label: `Labor: (${Number(i.setup_cleanup_minutes)} setup/cleanup + ${Number(q.assembly_minutes)} assembly) min × ${money(i.labor_rate)}/h`, value: unitCost(c.labor), source: 'Settings' },
          { label: `Packaging: ${money(i.packaging_per_order)} per order ÷ ${q.qty}`, value: unitCost(c.packaging), source: 'Settings' },
          {
            label: `Failure allowance: (filament + machine + labor) × ${(Number(i.failure_rate) * 100).toFixed(1)}% ÷ (1 − ${(Number(i.failure_rate) * 100).toFixed(1)}%)`,
            value: unitCost(c.failure_allowance),
            source: `actual scrap: ${Number(i.units_scrapped)} of ${Number(i.units_started)} units in the last ${i.failure_window_days} days`,
          },
          { label: 'Cost per unit', value: unitCost(c.unit_cost), strong: true },
          { label: `× markup ${Number(i.markup)}, at least ${money(i.minimum_price)}`, value: money(q.unit_price), source: 'Settings', strong: true },
          { label: `Ready: print queue ${Number(i.queue_hours)} h (spread over ${i.printers} printers) + ⌈${q.qty} ÷ ${i.printers}⌉ × ${Number(q.print_hours)} h + ${q.qty} × ${Number(q.assembly_minutes)} min`, value: dateTime(q.ready_at), source: 'running and planned production orders; prints finishing after hours are done at 8 am' },
        ]}
      />
    </div>
  );
}
