import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ShowMath } from '../../app/ShowMath';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { money, unitCost } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';

// New Design wizard (wow factor #8): print data for a new product -> one item
// per color with barcode, bill of material, rolled-up cost and a suggested
// price. The database (preview_product_design / create_product_design) does
// all the checks and math; the preview equals the cost after creation.

interface Variant {
  color: string;
  sku: string;
  barcode: string;
  name: string;
  filament_cost_per_g: number;
  material_cost: number;
  machine_cost: number;
  labor_cost: number;
  unit_cost: number;
}
interface Plan {
  name: string;
  code: string;
  grams_per_plate: number;
  print_minutes: number;
  units_per_plate: number;
  assembly_minutes: number;
  components: { item_id: string; name: string; uom: string; qty_per_plate: number; unit_cost: number }[];
  component_cost_per_plate: number;
  variants: Variant[];
  inputs: { machine_rate_per_hour: number; labor_rate: number; setup_cleanup_minutes: number; markup: number };
  suggested_price: number;
  price: number;
  margin_pct: number | null;
}

const allColors = ['Red', 'White', 'Blue', 'Black'];

interface Form {
  name: string;
  code: string;
  description: string;
  colors: string[];
  grams_per_plate: string;
  print_minutes: string;
  units_per_plate: string;
  assembly_minutes: string;
  components: { item_id: string; qty_per_plate: string }[];
  length_in: string;
  width_in: string;
  height_in: string;
  packing_class: string;
  box_size: string;
  stocking_policy: 'make_to_order' | 'stock' | 'seasonal';
  season_start: string;
  season_end: string;
  lead_time_days: string;
  price: string;
}

const empty: Form = {
  name: '', code: '', description: '', colors: ['Blue'], grams_per_plate: '', print_minutes: '', units_per_plate: '1',
  assembly_minutes: '0', components: [], length_in: '', width_in: '', height_in: '', packing_class: 'standard', box_size: '',
  stocking_policy: 'make_to_order', season_start: '11-01', season_end: '12-31', lead_time_days: '', price: '',
};

function payload(f: Form): Record<string, unknown> | null {
  if (!f.name.trim() || !f.code.trim() || f.colors.length === 0 || !f.grams_per_plate || !f.print_minutes) return null;
  return {
    ...f,
    components: f.components.filter((c) => c.item_id),
    season_start: f.stocking_policy === 'seasonal' ? f.season_start : '',
    season_end: f.stocking_policy === 'seasonal' ? f.season_end : '',
  };
}

export function NewDesignPage() {
  const navigate = useNavigate();
  const comps = useLiveQuery(
    async () => unwrap<{ id: string; name: string; uom: string }[]>(await db().from('items').select('id, name, uom').eq('category', 'component').eq('is_active', true).order('name')),
    ['items'],
  );
  const [f, setF] = useState<Form>(empty);
  const [plan, setPlan] = useState<Plan | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pricing, setPricing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const seq = useRef(0);
  const p = payload(f);
  const key = p ? JSON.stringify(p) : '';

  useEffect(() => {
    const mine = ++seq.current;
    if (!key) {
      setPlan(null);
      setError(null);
      return;
    }
    setPricing(true);
    const t = window.setTimeout(async () => {
      try {
        const r = await rpc<Plan>('preview_product_design', { p: JSON.parse(key) });
        if (mine === seq.current) {
          setPlan(r);
          setError(null);
        }
      } catch (e) {
        if (mine === seq.current) {
          setPlan(null);
          setError(errorMessage(e));
        }
      } finally {
        if (mine === seq.current) setPricing(false);
      }
    }, 350);
    return () => window.clearTimeout(t);
  }, [key]);

  async function create() {
    if (!p) return;
    setBusy(true);
    setCreateError(null);
    try {
      const ids = await rpc<string[]>('create_product_design', { p });
      navigate(`/inventory/item/${ids[0]}`);
    } catch (e) {
      setCreateError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const up = (k: keyof Form) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  if (comps.loading) return <Loading what="components" />;
  if (comps.error) return <ErrorNotice message={comps.error} />;

  return (
    <div>
      <PageHeader
        title="New product design"
        subtitle="Enter the slicer's numbers for one plate. You get one item per color with its own barcode and bill of material, the rolled-up cost and a suggested price. It is sellable right away (POS, sales orders, portal) and shows up in MRP and production."
      />
      <div className="pos-grid">
        <div className="card form">
          <div className="form-row">
            <label className="grow">
              Product name
              <input value={f.name} maxLength={40} onChange={up('name')} placeholder="e.g. Rocket" />
            </label>
            <label>
              Code (2–4 letters)
              <input value={f.code} maxLength={4} onChange={(e) => setF({ ...f, code: e.target.value.toUpperCase().replace(/[^A-Z]/g, '') })} placeholder="RKT" />
            </label>
          </div>
          <label>
            Description (optional)
            <input value={f.description} maxLength={300} onChange={up('description')} />
          </label>
          <fieldset className="discount">
            <legend>Colors (one item each)</legend>
            <div className="choice-row">
              {allColors.map((c) => (
                <label key={c} className="check">
                  <input
                    type="checkbox"
                    checked={f.colors.includes(c)}
                    onChange={(e) => setF({ ...f, colors: e.target.checked ? [...f.colors, c] : f.colors.filter((x) => x !== c) })}
                  />{' '}
                  {c}
                </label>
              ))}
            </div>
          </fieldset>
          <div className="form-row">
            <label>
              Filament per plate (g)
              <input type="number" min="0.1" step="0.1" value={f.grams_per_plate} onChange={up('grams_per_plate')} />
            </label>
            <label>
              Print time per plate (min)
              <input type="number" min="1" step="1" value={f.print_minutes} onChange={up('print_minutes')} />
            </label>
            <label>
              Units per plate
              <input type="number" min="1" max="100" step="1" value={f.units_per_plate} onChange={up('units_per_plate')} />
            </label>
            <label>
              Assembly per plate (min)
              <input type="number" min="0" step="1" value={f.assembly_minutes} onChange={up('assembly_minutes')} />
            </label>
          </div>
          <fieldset className="discount">
            <legend>Components per plate (optional)</legend>
            {f.components.map((c, i) => (
              <div key={i} className="inline-form">
                <select
                  value={c.item_id}
                  onChange={(e) => setF({ ...f, components: f.components.map((x, j) => (j === i ? { ...x, item_id: e.target.value } : x)) })}
                >
                  <option value="">Choose a component…</option>
                  {(comps.data ?? []).map((ci) => <option key={ci.id} value={ci.id}>{ci.name} ({ci.uom})</option>)}
                </select>
                <input
                  className="qty-input"
                  type="number"
                  min="0"
                  step="any"
                  value={c.qty_per_plate}
                  onChange={(e) => setF({ ...f, components: f.components.map((x, j) => (j === i ? { ...x, qty_per_plate: e.target.value } : x)) })}
                  aria-label="Quantity per plate"
                />
                <button type="button" className="btn link" onClick={() => setF({ ...f, components: f.components.filter((_, j) => j !== i) })}>Remove</button>
              </div>
            ))}
            <div>
              <button type="button" className="btn" onClick={() => setF({ ...f, components: [...f.components, { item_id: '', qty_per_plate: '1' }] })}>+ Add component</button>
            </div>
          </fieldset>
          <div className="form-row">
            <label>
              Length (in)
              <input type="number" min="0" step="0.1" value={f.length_in} onChange={up('length_in')} />
            </label>
            <label>
              Width (in)
              <input type="number" min="0" step="0.1" value={f.width_in} onChange={up('width_in')} />
            </label>
            <label>
              Height (in)
              <input type="number" min="0" step="0.1" value={f.height_in} onChange={up('height_in')} />
            </label>
            <label>
              Packing class
              <select value={f.packing_class} onChange={up('packing_class')}>
                <option value="small">Small</option>
                <option value="standard">Standard</option>
                <option value="multi_piece">Multi-piece</option>
                <option value="fragile">Fragile</option>
              </select>
            </label>
          </div>
          <div className="form-row">
            <label>
              Stocking
              <select value={f.stocking_policy} onChange={(e) => setF({ ...f, stocking_policy: e.target.value as Form['stocking_policy'] })}>
                <option value="make_to_order">Made to order</option>
                <option value="stock">Stocked</option>
                <option value="seasonal">Seasonal</option>
              </select>
            </label>
            {f.stocking_policy === 'seasonal' && (
              <>
                <label>
                  Season start (MM-DD)
                  <input className="state-input" style={{ width: 90 }} value={f.season_start} onChange={up('season_start')} />
                </label>
                <label>
                  Season end (MM-DD)
                  <input className="state-input" style={{ width: 90 }} value={f.season_end} onChange={up('season_end')} />
                </label>
              </>
            )}
            <label>
              Production lead time (days)
              <input type="number" min="0" max="60" step="1" value={f.lead_time_days} onChange={up('lead_time_days')} placeholder="default" />
            </label>
          </div>
        </div>

        <div className="card form pos-pay">
          {!p && <p className="muted">Enter a name, code, at least one color, grams and print time to see costs.</p>}
          {error && <div className="notice error">{error}</div>}
          {pricing && !plan && <p className="muted">Calculating…</p>}
          {plan && (
            <div className={pricing ? 'repricing' : ''}>
              <table className="table">
                <thead>
                  <tr><th>Item</th><th className="num">Unit cost</th></tr>
                </thead>
                <tbody>
                  {plan.variants.map((v) => (
                    <tr key={v.sku}>
                      <td>{v.name}<div className="muted small">{v.sku} · barcode {v.barcode}</div></td>
                      <td className="num">{unitCost(v.unit_cost)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <ShowMath
                formula="unit cost = (filament g × cost/g + components + print hours × machine rate + (setup + cleanup + assembly) min ÷ 60 × labor rate) ÷ units per plate"
                rows={[
                  ...plan.variants.map((v) => ({
                    label: `${v.color}: ${Number(plan.grams_per_plate)} g × ${unitCost(v.filament_cost_per_g)}/g + components ${unitCost(plan.component_cost_per_plate)}, ÷ ${plan.units_per_plate}`,
                    value: unitCost(v.material_cost),
                    source: 'weighted-average costs',
                  })),
                  { label: `Machine: ${Number(plan.print_minutes)} min ÷ 60 × ${unitCost(plan.inputs.machine_rate_per_hour)}/h ÷ ${plan.units_per_plate}`, value: unitCost(plan.variants[0]?.machine_cost), source: 'Settings' },
                  { label: `Labor: (${Number(plan.inputs.setup_cleanup_minutes)} + ${Number(plan.assembly_minutes)}) min ÷ 60 × ${money(plan.inputs.labor_rate)}/h ÷ ${plan.units_per_plate}`, value: unitCost(plan.variants[0]?.labor_cost), source: 'Settings' },
                  { label: `Suggested price = highest unit cost × ${Number(plan.inputs.markup)}, rounded up to .99`, value: money(plan.suggested_price), source: 'Settings: new design markup', strong: true },
                ]}
              />
              <label>
                Selling price
                <input type="number" min="0.01" step="0.01" value={f.price} onChange={up('price')} placeholder={`${Number(plan.suggested_price).toFixed(2)} (suggested)`} />
              </label>
              <p className="small" style={{ margin: '0.4rem 0' }}>
                Price {money(plan.price)} · margin {plan.margin_pct === null ? '—' : `${(Number(plan.margin_pct) * 100).toFixed(0)}%`} on the most expensive color
              </p>
            </div>
          )}
          {createError && <div className="notice error">{createError}</div>}
          <button className="btn primary big" disabled={!plan || pricing || !!error || busy} onClick={create}>
            {busy ? 'Creating…' : `Create ${plan ? plan.variants.length : ''} item${plan && plan.variants.length === 1 ? '' : 's'}`}
          </button>
          <p className="muted small">Retire it later with "Retire product" on any of its item pages; history stays.</p>
        </div>
      </div>
    </div>
  );
}
