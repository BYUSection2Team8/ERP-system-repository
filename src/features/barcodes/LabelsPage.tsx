import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { money } from '../../lib/format';
import type { Item } from '../../lib/types';
import { categoryLabels, useInventoryData } from '../inventory/useInventoryData';
import { Barcode } from './Barcode';

/**
 * Printable Code 128 label sheet. Layout matches Avery 5160 / 8160
 * (30 labels per US Letter sheet, 2-5/8" x 1"). Plain paper works too:
 * cut the labels out and tape them on. Print at 100% scale ("Actual size").
 */
export function LabelsPage() {
  const { data, error, loading } = useInventoryData();
  const [params] = useSearchParams();
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [category, setCategory] = useState('product');
  const [skip, setSkip] = useState(0);

  useEffect(() => {
    const id = params.get('item');
    if (id && data && !(id in counts)) {
      setCounts((c) => ({ ...c, [id]: 1 }));
      const it = data.items.find((i) => i.id === id);
      if (it) setCategory(it.category);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data, params]);

  if (loading) return <Loading />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;

  const shown = data.items.filter((i) => category === 'all' || i.category === category);
  const labels: Item[] = [];
  for (const i of data.items) for (let k = 0; k < (counts[i.id] ?? 0); k++) labels.push(i);
  const set = (id: string, n: number) => setCounts((c) => ({ ...c, [id]: Math.max(0, Math.min(300, n || 0)) }));

  return (
    <div>
      <PageHeader
        title="Barcode labels"
        subtitle="Code 128 labels for Avery 5160 sheets (30 per page). Print at 100% / actual size."
        actions={
          <button className="btn primary" disabled={labels.length === 0} onClick={() => window.print()}>
            Print {labels.length} label{labels.length === 1 ? '' : 's'}
          </button>
        }
      />

      <div className="no-print">
        <div className="toolbar">
          <select value={category} onChange={(e) => setCategory(e.target.value)} aria-label="Category">
            <option value="all">All categories</option>
            {Object.entries(categoryLabels).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
          <button className="btn" onClick={() => shown.forEach((i) => set(i.id, (counts[i.id] ?? 0) + 1))}>
            +1 of each shown
          </button>
          <button className="btn" onClick={() => setCounts({})}>Clear all</button>
          <label className="check">
            Skip first
            <input className="qty-input" type="number" min="0" max="29" value={skip}
              onChange={(e) => setSkip(Math.max(0, Math.min(29, Number(e.target.value) || 0)))} />
            labels (partly used sheet)
          </label>
        </div>

        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>Item</th><th>Barcode</th><th className="num">Labels</th></tr></thead>
            <tbody>
              {shown.map((i) => (
                <tr key={i.id}>
                  <td>{i.name}<div className="muted small">{i.sku}</div></td>
                  <td className="mono">{i.barcode}</td>
                  <td className="num">
                    <input className="qty-input" type="number" min="0" value={counts[i.id] ?? 0}
                      onChange={(e) => set(i.id, Number(e.target.value))} aria-label={`Labels for ${i.name}`} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <h2>Preview</h2>
      </div>

      <div className="label-sheet">
        {Array.from({ length: labels.length > 0 ? skip : 0 }, (_, k) => <div key={`skip${k}`} className="label blank" />)}
        {labels.map((i, k) => (
          <div key={`${i.id}-${k}`} className="label">
            <div className="label-top">
              <span className="label-name">{i.name}</span>
              {i.price !== null && <span className="label-price">{money(i.price)}</span>}
            </div>
            <Barcode value={i.barcode} height={34} moduleWidth={1.2} />
          </div>
        ))}
      </div>
    </div>
  );
}
