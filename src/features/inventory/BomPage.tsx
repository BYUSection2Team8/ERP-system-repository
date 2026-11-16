import { Link, useSearchParams } from 'react-router-dom';
import { ShowMath } from '../../app/ShowMath';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { money, qty, unitCost } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';

// Bills of materials: one tab per product, every color's components per plate
// and per unit, current weighted-average costs, Print Farm stock (how many plates
// can be built now) and the rolled-up cost. All read from the stored BOMs, stock
// movements and settings (item_standard_cost), so it changes when they change.

interface Product {
  id: string;
  sku: string;
  name: string;
  product_family: string | null;
  color: string | null;
  units_per_plate: number;
  print_minutes: number | null;
  assembly_minutes: number | null;
  price: number | null;
  stocking_policy: string;
  is_custom: boolean;
}
interface Bom {
  parent_item_id: string;
  component_item_id: string;
  qty_per_plate: number;
}
interface Comp {
  id: string;
  sku: string;
  name: string;
  uom: 'ea' | 'g';
  category: string;
}
interface Std {
  item_id: string;
  material_cost: number;
  machine_cost: number;
  labor_cost: number;
  total_cost: number;
  margin_pct: number | null;
}

async function load() {
  const c = db();
  const [products, boms, items, vals, std, farm, settings] = await Promise.all([
    c.from('items').select('id, sku, name, product_family, color, units_per_plate, print_minutes, assembly_minutes, price, stocking_policy, is_custom')
      .eq('item_type', 'finished').eq('is_active', true).order('name').then(unwrap<Product[]>),
    c.from('boms').select('parent_item_id, component_item_id, qty_per_plate').then(unwrap<Bom[]>),
    c.from('items').select('id, sku, name, uom, category').then(unwrap<Comp[]>),
    c.from('v_inventory_valuation').select('item_id, avg_unit_cost').then(unwrap<{ item_id: string; avg_unit_cost: number }[]>),
    c.from('v_item_standard_cost').select('item_id, material_cost, machine_cost, labor_cost, total_cost, margin_pct').then(unwrap<Std[]>),
    c.from('locations').select('id').eq('code', 'PRINT_FARM').maybeSingle().then(unwrap<{ id: string } | null>),
    c.from('settings').select('key, value').in('key', ['labor_rate', 'setup_minutes_per_plate', 'cleanup_minutes_per_plate']).then(unwrap<{ key: string; value: string }[]>),
  ]);
  const onHand = farm
    ? await c.from('v_availability').select('item_id, qty_on_hand').eq('location_id', farm.id).then(unwrap<{ item_id: string; qty_on_hand: number }[]>)
    : [];
  const s = new Map(settings.map((x) => [x.key, Number(x.value)]));
  return {
    products,
    boms,
    comp: new Map(items.map((i) => [i.id, i])),
    cost: new Map(vals.map((v) => [v.item_id, Number(v.avg_unit_cost)])),
    std: new Map(std.map((x) => [x.item_id, x])),
    farm: new Map(onHand.map((o) => [o.item_id, Number(o.qty_on_hand)])),
    laborRate: s.get('labor_rate') ?? 0,
    setupMin: (s.get('setup_minutes_per_plate') ?? 0) + (s.get('cleanup_minutes_per_plate') ?? 0),
  };
}

type Data = Awaited<ReturnType<typeof load>>;

export function BomPage() {
  const { data, error, loading } = useLiveQuery(load, ['boms', 'items', 'inventory_txn', 'settings']);
  const [params, setParams] = useSearchParams();

  if (loading) return <Loading what="bills of materials" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;

  const withBom = new Set(data.boms.map((b) => b.parent_item_id));
  const families = new Map<string, Product[]>();
  for (const p of data.products) {
    if (!withBom.has(p.id)) continue;
    const k = p.is_custom ? 'Custom prints' : p.product_family ?? p.name;
    families.set(k, [...(families.get(k) ?? []), p]);
  }
  const keys = [...families.keys()].sort((a, b) => (a === 'Custom prints' ? 1 : b === 'Custom prints' ? -1 : a.localeCompare(b)));
  const tab = params.get('p') && families.has(params.get('p')!) ? params.get('p')! : 'overview';
  const variants = families.get(tab) ?? [];
  const picked = variants.find((v) => v.id === params.get('item')) ?? variants[0];

  return (
    <div>
      <PageHeader
        title="Bills of materials"
        subtitle="What goes into one plate of each product, what it costs now, and how many plates the Print Farm can build with the stock on hand. Costs are weighted-average costs from the stock movements plus machine time and labor from Settings."
        actions={<Link className="btn" to="/inventory/new-design">New product design</Link>}
      />
      <div className="tabs no-print">
        <button type="button" className={tab === 'overview' ? 'active' : ''} onClick={() => setParams({}, { replace: true })}>All products</button>
        {keys.map((k) => (
          <button key={k} type="button" className={tab === k ? 'active' : ''} onClick={() => setParams({ p: k }, { replace: true })}>
            {k}
          </button>
        ))}
      </div>
      {tab === 'overview' ? <Overview data={data} families={families} keys={keys} onPick={(k) => setParams({ p: k })} /> : picked && (
        <>
          {variants.length > 1 && (
            <div className="swatches spaced" role="group" aria-label="Variant">
              {variants.map((v) => (
                <button key={v.id} type="button" className={`swatch ${v.id === picked.id ? 'active' : ''}`} onClick={() => setParams({ p: tab, item: v.id }, { replace: true })}>
                  {v.color ?? v.name}
                </button>
              ))}
            </div>
          )}
          <ItemBom data={data} item={picked} />
        </>
      )}
    </div>
  );
}

function Overview({ data, families, keys, onPick }: { data: Data; families: Map<string, Product[]>; keys: string[]; onPick: (k: string) => void }) {
  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            <th>Product</th>
            <th className="num">Colors</th>
            <th className="num">Units / plate</th>
            <th className="num">Components</th>
            <th className="num">Rolled-up cost</th>
            <th className="num">Price</th>
            <th className="num">Margin</th>
          </tr>
        </thead>
        <tbody>
          {keys.map((k) => {
            const vs = families.get(k)!;
            const costs = vs.map((v) => Number(data.std.get(v.id)?.total_cost ?? 0));
            const lo = Math.min(...costs);
            const hi = Math.max(...costs);
            const price = Number(vs[0].price ?? 0);
            const comps = new Set(data.boms.filter((b) => vs.some((v) => v.id === b.parent_item_id)).map((b) => data.comp.get(b.component_item_id)?.category === 'filament' ? 'filament' : b.component_item_id));
            return (
              <tr key={k} className="clickable" onClick={() => onPick(k)}>
                <td><strong>{k}</strong>{k === 'Custom prints' && <div className="muted small">made from quotes</div>}</td>
                <td className="num">{vs.length}</td>
                <td className="num">{vs[0].units_per_plate}</td>
                <td className="num">{comps.size}</td>
                <td className="num">{lo === hi ? unitCost(lo) : `${unitCost(lo)} – ${unitCost(hi)}`}</td>
                <td className="num">{k === 'Custom prints' ? 'per quote' : money(price)}</td>
                <td className="num">{price > 0 && k !== 'Custom prints' ? `${(((price - hi) / price) * 100).toFixed(0)}%` : '—'}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function ItemBom({ data, item }: { data: Data; item: Product }) {
  const lines = data.boms
    .filter((b) => b.parent_item_id === item.id)
    .map((b) => {
      const c = data.comp.get(b.component_item_id)!;
      const perUnit = Number(b.qty_per_plate) / item.units_per_plate;
      const cost = data.cost.get(c.id) ?? 0;
      const have = data.farm.get(c.id) ?? 0;
      return { b, c, perUnit, cost, ext: perUnit * cost, have, plates: Math.floor(have / Number(b.qty_per_plate)) };
    })
    .sort((a, b) => (a.c.category === 'filament' ? -1 : 0) - (b.c.category === 'filament' ? -1 : 0) || a.c.name.localeCompare(b.c.name));
  const std = data.std.get(item.id);
  const canBuild = lines.length ? Math.min(...lines.map((l) => l.plates)) : 0;
  const limiting = lines.find((l) => l.plates === canBuild);
  const price = Number(item.price ?? 0);
  const printH = Number(item.print_minutes ?? 0) / 60;

  return (
    <>
      <div className="stats">
        <Stat label="Rolled-up cost per unit" value={unitCost(std?.total_cost)} hint={`materials ${unitCost(std?.material_cost)} · machine ${unitCost(std?.machine_cost)} · labor ${unitCost(std?.labor_cost)}`} />
        <Stat label="Price / margin" value={item.is_custom ? 'per quote' : money(price)} hint={std?.margin_pct != null ? `${(Number(std.margin_pct) * 100).toFixed(0)}% margin` : undefined} />
        <Stat label="Per plate" value={`${item.units_per_plate} unit${item.units_per_plate === 1 ? '' : 's'}`} hint={`${printH.toFixed(2)} h print · ${Number(item.assembly_minutes ?? 0)} min assembly`} />
        <Stat
          label="Can build now (Print Farm)"
          value={`${canBuild} plate${canBuild === 1 ? '' : 's'}`}
          hint={limiting ? `= ${canBuild * item.units_per_plate} units; limited by ${limiting.c.name}` : undefined}
          tone={canBuild === 0 ? 'warn' : undefined}
        />
      </div>
      <div className="page-actions spaced">
        <Link className="btn" to={`/inventory/item/${item.id}`}>Item page ({item.sku})</Link>
        <Link className="btn" to="/production/new">New production order</Link>
        <Link className="btn" to="/mrp">MRP</Link>
      </div>
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr>
              <th>Component</th>
              <th className="num">Per plate</th>
              <th className="num">Per unit</th>
              <th className="num">Avg cost</th>
              <th className="num">Cost per unit</th>
              <th className="num">At Print Farm</th>
              <th className="num">Plates possible</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.c.id} className={l.plates === canBuild ? 'row-alert' : ''}>
                <td><Link to={`/inventory/item/${l.c.id}`}>{l.c.name}</Link><div className="muted small">{l.c.sku}</div></td>
                <td className="num">{qty(l.b.qty_per_plate, l.c.uom)}</td>
                <td className="num">{qty(Number(l.perUnit.toFixed(4)), l.c.uom)}</td>
                <td className="num">{unitCost(l.cost)}{l.c.uom === 'g' ? '/g' : ''}</td>
                <td className="num">{unitCost(l.ext)}</td>
                <td className="num">{qty(l.have, l.c.uom)}</td>
                <td className="num strong">{l.plates}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr><td colSpan={4}>Materials per unit</td><td className="num">{unitCost(std?.material_cost)}</td><td colSpan={2} /></tr>
          </tfoot>
        </table>
      </div>
      <ShowMath
        formula="unit cost = (Σ component qty per plate × avg cost + print hours × machine rate + (setup + cleanup + assembly) min ÷ 60 × labor rate) ÷ units per plate"
        rows={[
          { label: 'Materials: Σ qty per plate × weighted-average cost ÷ units per plate', value: unitCost(std?.material_cost), source: 'stock movements' },
          { label: `Machine: ${printH.toFixed(2)} h × machine rate ÷ ${item.units_per_plate}`, value: unitCost(std?.machine_cost), source: 'Settings (printer cost, power, maintenance)' },
          { label: `Labor: (${data.setupMin} + ${Number(item.assembly_minutes ?? 0)}) min ÷ 60 × ${money(data.laborRate)}/h ÷ ${item.units_per_plate}`, value: unitCost(std?.labor_cost), source: 'Settings' },
          { label: 'Rolled-up cost per unit', value: unitCost(std?.total_cost), strong: true },
          { label: 'Can build now = the smallest of (Print Farm stock ÷ qty per plate) over the components', value: `${canBuild} plates`, source: 'Print Farm on hand' },
        ]}
      />
    </>
  );
}
