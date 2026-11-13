import { useState } from 'react';
import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { dateTime } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { Barcode } from '../barcodes/Barcode';
import { CameraScanner } from '../barcodes/CameraScanner';

// Filament spools (wow factor #5): every spool has a barcode and grams left.
// Spools follow the filament stock movements in the database (receipts create
// them, prints draw from the spool loaded on the printer), so spool grams
// always equal the filament on hand.

interface Spool {
  id: string;
  spool_no: string;
  barcode: string;
  item_id: string;
  grams_initial: number;
  grams_left: number;
  status: 'in_stock' | 'loaded' | 'empty';
  printer_id: string | null;
  ams_slot: number | null;
  loaded_at: string | null;
  item: { name: string; color: string | null } | null;
}
interface Printer {
  id: string;
  name: string;
  is_active: boolean;
}
interface Recon {
  item_id: string;
  name: string;
  grams_on_hand: number;
  grams_on_spools: number;
  spools: number;
  near_empty: number;
}

async function load() {
  const c = db();
  const [spools, printers, recon, low] = await Promise.all([
    c.from('spools').select('*, item:items(name, color)').neq('status', 'empty').order('spool_no').then((r) => unwrap(r) as unknown as Spool[]),
    c.from('printers').select('id, name, is_active').order('sort_order').then(unwrap<Printer[]>),
    c.from('v_spool_reconciliation').select('*').order('name').then(unwrap<Recon[]>),
    c.from('settings').select('value').eq('key', 'spool_low_grams').maybeSingle().then(unwrap<{ value: string } | null>),
  ]);
  return { spools, printers, recon, low: Number(low?.value ?? 100) };
}

const colorSwatch: Record<string, string> = { Red: '#c0392b', White: '#e8e8e8', Blue: '#1f5fbf', Black: '#222' };

function GramsBar({ s, low }: { s: Spool; low: number }) {
  const pct = Math.max(0, Math.min(100, (Number(s.grams_left) / Number(s.grams_initial || 985)) * 100));
  const isLow = Number(s.grams_left) < low;
  return (
    <div>
      <div className={`space-bar ${isLow ? 'bad' : 'ok'}`}><span style={{ width: `${pct}%` }} /></div>
      <div className={`small ${isLow ? 'bad strong' : 'muted'}`}>{Number(s.grams_left).toLocaleString()} g left{isLow ? ' · near empty' : ''}</div>
    </div>
  );
}

export function SpoolsPage() {
  const { data, error, loading } = useLiveQuery(load, ['spools', 'printers', 'inventory_txn', 'settings']);
  const [code, setCode] = useState('');
  const [printer, setPrinter] = useState('');
  const [slot, setSlot] = useState('1');
  const [weight, setWeight] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [camera, setCamera] = useState(false);
  const [labels, setLabels] = useState<string[]>([]);

  async function act(fn: string, args: Record<string, unknown>, done: string) {
    setMsg(null);
    try {
      await rpc(fn, args);
      setMsg({ ok: true, text: done });
    } catch (e) {
      setMsg({ ok: false, text: errorMessage(e) });
    }
  }

  if (loading) return <Loading what="spools" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const printerId = printer || data.printers[0]?.id || '';
  const inStock = data.spools.filter((s) => s.status === 'in_stock');
  const low = data.spools.filter((s) => Number(s.grams_left) < data.low);
  const scanned = data.spools.find((s) => s.barcode === code.trim().toUpperCase() || s.spool_no === code.trim().toUpperCase());
  const labelSpools = data.spools.filter((s) => labels.includes(s.id));

  return (
    <div>
      <PageHeader
        title="Filament spools"
        subtitle="Each spool has its own barcode and grams left. Receipts create spools; every print takes its grams off the spool of that color loaded on its printer and loads the next spool when one runs out. Spool grams always add up to the filament on hand."
        actions={<Link className="btn" to="/production/printers">Printer board</Link>}
      />
      <div className="stats">
        <Stat label="Spools in use" value={data.spools.filter((s) => s.status === 'loaded').length} hint={`${data.printers.length} printers × 4 AMS slots`} />
        <Stat label="Spools in stock" value={inStock.length} />
        <Stat label="Near empty" value={low.length} hint={`under ${data.low} g`} tone={low.length > 0 ? 'warn' : undefined} />
      </div>

      <div className="card action-card no-print">
        <h2 style={{ margin: 0 }}>Scan a spool</h2>
        <div className="form-row">
          <label className="grow">
            Spool barcode
            <div className="scan-row">
              <input value={code} onChange={(e) => setCode(e.target.value)} placeholder="PP-SP-1001 (USB scanner or type)" autoFocus />
              <button type="button" className="btn" onClick={() => setCamera(true)} aria-label="Scan with camera">📷</button>
            </div>
          </label>
        </div>
        {code && !scanned && <div className="muted small">No active spool with that barcode.</div>}
        {scanned && (
          <>
            <div className="small">
              <strong>{scanned.spool_no}</strong> · {scanned.item?.name} · {Number(scanned.grams_left)} g left ·{' '}
              {scanned.status === 'loaded' ? `in ${data.printers.find((p) => p.id === scanned.printer_id)?.name} slot ${scanned.ams_slot}` : 'in stock'}
            </div>
            <div className="form-row">
              <label>
                Printer
                <select value={printerId} onChange={(e) => setPrinter(e.target.value)}>
                  {data.printers.filter((p) => p.is_active).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                </select>
              </label>
              <label>
                AMS slot
                <select value={slot} onChange={(e) => setSlot(e.target.value)}>
                  {[1, 2, 3, 4].map((n) => <option key={n}>{n}</option>)}
                </select>
              </label>
              <button className="btn primary" onClick={() => act('load_spool', { p_barcode: scanned.barcode, p_printer: printerId, p_slot: Number(slot) }, `${scanned.spool_no} loaded.`)}>Load</button>
              {scanned.status === 'loaded' && (
                <button className="btn" onClick={() => act('unload_spool', { p_barcode: scanned.barcode }, `${scanned.spool_no} back in stock.`)}>Unload</button>
              )}
            </div>
            <div className="form-row">
              <label>
                Weighed filament left (g)
                <input type="number" min="0" step="1" value={weight} onChange={(e) => setWeight(e.target.value)} />
              </label>
              <button
                className="btn"
                disabled={weight === '' || Number(weight) < 0}
                onClick={() => act('weigh_spool', { p_barcode: scanned.barcode, p_grams: Number(weight) }, `${scanned.spool_no} set to ${weight} g (cycle count posted).`)}
              >
                Record weight
              </button>
            </div>
          </>
        )}
        {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'}`}>{msg.text}</div>}
      </div>
      {camera && <CameraScanner onScan={(t) => { setCode(t); setCamera(false); }} onClose={() => setCamera(false)} />}

      <h2>In the printers</h2>
      <div className="printer-grid">
        {data.printers.map((p) => (
          <div key={p.id} className="card printer-card">
            <h2 style={{ margin: 0 }}>{p.name}</h2>
            {[1, 2, 3, 4].map((n) => {
              const s = data.spools.find((x) => x.printer_id === p.id && x.ams_slot === n && x.status === 'loaded');
              return (
                <div key={n} className="ams-slot">
                  <span className="muted small">Slot {n}</span>
                  {s ? (
                    <div>
                      <span className="swatch-dot" style={{ background: colorSwatch[s.item?.color ?? ''] ?? '#999' }} /> {s.item?.color ?? s.item?.name} · {s.spool_no}
                      <GramsBar s={s} low={data.low} />
                    </div>
                  ) : (
                    <span className="muted small">empty</span>
                  )}
                </div>
              );
            })}
          </div>
        ))}
      </div>

      <h2>In stock ({inStock.length})</h2>
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr><th className="no-print">Label</th><th>Spool</th><th>Filament</th><th style={{ minWidth: 160 }}>Left</th></tr>
          </thead>
          <tbody>
            {inStock.map((s) => (
              <tr key={s.id}>
                <td className="no-print"><input type="checkbox" checked={labels.includes(s.id)} onChange={(e) => setLabels(e.target.checked ? [...labels, s.id] : labels.filter((x) => x !== s.id))} aria-label={`Label for ${s.spool_no}`} /></td>
                <td>{s.spool_no}<div className="muted small">{s.barcode}</div></td>
                <td>{s.item?.name}</td>
                <td><GramsBar s={s} low={data.low} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2>Spools vs filament on hand</h2>
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr><th>Filament</th><th className="num">On hand (stock movements)</th><th className="num">On spools</th><th className="num">Spools</th><th className="num">Near empty</th></tr>
          </thead>
          <tbody>
            {data.recon.map((r) => (
              <tr key={r.item_id}>
                <td>{r.name}</td>
                <td className="num">{Number(r.grams_on_hand).toLocaleString()} g</td>
                <td className={`num ${Math.abs(Number(r.grams_on_hand) - Number(r.grams_on_spools)) > 0.05 ? 'bad' : 'good'}`}>{Number(r.grams_on_spools).toLocaleString()} g</td>
                <td className="num">{r.spools}</td>
                <td className="num">{r.near_empty}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {labelSpools.length > 0 && (
        <>
          <div className="page-actions no-print" style={{ margin: '1rem 0' }}>
            <button className="btn primary" onClick={() => window.print()}>Print {labelSpools.length} spool label{labelSpools.length === 1 ? '' : 's'}</button>
            <span className="muted small">Avery 5160 or plain paper at 100% scale. Updated {dateTime(new Date().toISOString())}.</span>
          </div>
          <div className="label-sheet">
            {labelSpools.map((s) => (
              <div key={s.id} className="label">
                <div className="label-top">
                  <span className="label-name">{s.item?.name}</span>
                  <span className="label-price">{s.spool_no}</span>
                </div>
                <Barcode value={s.barcode} height={34} moduleWidth={1.3} />
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  );
}
