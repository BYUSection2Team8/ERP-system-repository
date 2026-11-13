import { ShowMath } from '../../app/ShowMath';
import { ErrorNotice } from '../../app/ui';
import { rpc } from '../../lib/db';
import { money } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';

// Automatic box selection (wow factor #6): the database packs the order into
// the fewest, smallest boxes and explains why.

interface Pack {
  order_no: string;
  counter: boolean;
  fulfillment_method?: string;
  units?: number;
  box_count?: number;
  oversize_units?: number;
  fill_limit?: number;
  boxes: { box: string; sku: string; inside: string; fill: number; units: number; cost: number; contents: { name: string; qty: number }[] }[];
  box_cost?: number;
  tissue_cost?: number;
  card_cost?: number;
  packaging_cost?: number;
  flat_packaging_setting?: number;
  packing_minutes?: number;
  packing_labor_cost?: number;
}

export function PackingSlip({ soId }: { soId: string }) {
  const { data, error } = useLiveQuery(() => rpc<Pack>('pack_order', { p_so_id: soId }), ['sales_order_lines', 'settings', 'items'], [soId]);
  if (error) return <ErrorNotice message={error} />;
  if (!data || data.counter) return null;
  return (
    <div className="card spaced">
      <h2 style={{ marginTop: 0 }}>Packing slip · {data.box_count} box{data.box_count === 1 ? '' : 'es'}</h2>
      {Number(data.oversize_units) > 0 && <div className="notice warn">{data.oversize_units} unit(s) are bigger than every box; they are put in the largest box, so check by hand.</div>}
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr><th>Box</th><th>Contents</th><th className="num">Filled</th><th className="num">Box cost</th></tr>
          </thead>
          <tbody>
            {data.boxes.map((b, i) => (
              <tr key={i}>
                <td>{i + 1}. {b.box}<div className="muted small">inside {b.inside}</div></td>
                <td>{b.contents.map((c) => `${c.qty} × ${c.name}`).join(', ')}</td>
                <td className="num">{(Number(b.fill) * 100).toFixed(0)}%</td>
                <td className="num">{money(b.cost)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="small" style={{ margin: '0.5rem 0 0' }}>
        Packing time about <strong>{Number(data.packing_minutes)} min</strong> ({money(data.packing_labor_cost)} of labor) · packaging {money(data.packaging_cost)}
        <span className="muted"> (the P&amp;L uses the flat {money(data.flat_packaging_setting)} per order setting)</span>
      </p>
      <ShowMath
        formula={`Largest items first. Each item goes into an open box if its sorted sides fit the box's sorted inside sides and the box stays under ${(Number(data.fill_limit) * 100).toFixed(0)}% full; otherwise we open the smallest box that holds everything left, or else the largest box that fits it.`}
        rows={[
          { label: `Boxes (weighted-average cost)`, value: money(data.box_cost), source: 'Shipping box items' },
          { label: 'Tissue (sheets per box × cost)', value: money(data.tissue_cost), source: 'Settings + tissue item' },
          { label: 'Thank-you card', value: money(data.card_cost) },
          { label: 'Packaging total', value: money(data.packaging_cost), strong: true },
          { label: `Packing minutes = boxes × per-box minutes + each unit's packing-class minutes${data.fulfillment_method === 'pickup' ? ' − pickup saving per box' : ''}`, value: `${Number(data.packing_minutes)} min`, source: 'Settings' },
        ]}
      />
    </div>
  );
}
