import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { JournalTables } from '../../app/JournalTables';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { date, dateTime, money, qty, unitCost } from '../../lib/format';
import type { Account, ApOpen, Item, LedgerRow, Location, PoReceipt, PurchaseOrder, PurchaseOrderLine, Supplier } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { ScanItemInput } from '../barcodes/ScanItemInput';
import { nowLocalInput } from '../production/productionShared';
import { PoStatusBadge, poSourceLabels } from './purchasingShared';

interface LineView extends PurchaseOrderLine {
  item: Item;
}

async function load(id: string) {
  const c = db();
  const po = await c.from('purchase_orders').select('*').eq('id', id).maybeSingle().then(unwrap<PurchaseOrder | null>);
  if (!po) throw new Error('That purchase order does not exist.');
  const [supplier, lines, receipts, locations, accounts, bills] = await Promise.all([
    c.from('suppliers').select('*').eq('id', po.supplier_id).single().then(unwrap<Supplier>),
    c.from('purchase_order_lines').select('*, item:items(*)').eq('po_id', id).order('line_no').then((r) => unwrap(r) as unknown as LineView[]),
    c.from('po_receipts').select('*').eq('po_id', id).order('received_at').then(unwrap<PoReceipt[]>),
    c.from('locations').select('*').eq('is_active', true).order('sort_order').then(unwrap<Location[]>),
    c.from('accounts').select('code, name, type').then(unwrap<Account[]>),
    c.from('v_ap_open').select('*').eq('po_id', id).then(unwrap<ApOpen[]>),
  ]);
  const receiptIds = receipts.map((r) => r.id);
  const [payments, receiptLines] = await Promise.all([
    receiptIds.length
      ? c.from('supplier_payments').select('id, receipt_id, amount, paid_at').in('receipt_id', receiptIds).then(unwrap<{ id: string; receipt_id: string; amount: number; paid_at: string }[]>)
      : Promise.resolve([]),
    receiptIds.length
      ? c.from('po_receipt_lines').select('*').in('receipt_id', receiptIds).then(unwrap<{ receipt_id: string; po_line_id: string; qty_received: number }[]>)
      : Promise.resolve([]),
  ]);
  const ledgerIds = [...receiptIds, ...payments.map((p) => p.id)];
  const ledger = ledgerIds.length
    ? await c.from('ledger').select('id, journal_id, posted_at, account_code, debit, credit, source_type, memo').in('source_id', ledgerIds)
        .order('posted_at').order('id').then(unwrap<LedgerRow[]>)
    : [];
  return { po, supplier, lines, receipts, receiptLines, locations, accounts: new Map(accounts.map((a) => [a.code, a])), bills, payments, ledger };
}

/** Business-date difference in days (b - a) for YYYY-MM-DD / timestamps, in Utah time. */
function dayDiff(a: string, b: string): number {
  const f = (v: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Denver' }).format(new Date(/^\d{4}-\d{2}-\d{2}$/.test(v) ? `${v}T12:00:00` : v));
  return Math.round((new Date(`${f(b)}T12:00:00`).getTime() - new Date(`${f(a)}T12:00:00`).getTime()) / 86400000);
}

export function PurchaseOrderDetailPage() {
  const { id = '' } = useParams();
  const { data, error, loading } = useLiveQuery(() => load(id), ['purchase_orders', 'purchase_order_lines', 'po_receipts', 'supplier_payments', 'ledger'], [id]);
  const [recv, setRecv] = useState<Record<string, string>>({});
  const [loc, setLoc] = useState('');
  const [at, setAt] = useState(nowLocalInput());
  const [allowOver, setAllowOver] = useState(false);
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);
  const [scanMsg, setScanMsg] = useState<string | null>(null);

  if (loading) return <Loading what="purchase order" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const { po, supplier, lines, receipts } = data;
  const open = po.status === 'sent' || po.status === 'partial';
  const shipTo = data.locations.find((l) => l.id === po.ship_to_location_id);
  const receiveLoc = loc || po.ship_to_location_id;
  const remaining = (l: LineView) => Math.max(0, Number(l.qty_ordered) - Number(l.qty_received));
  const recvQty = (l: LineView) => (recv[l.id] === undefined ? remaining(l) : Number(recv[l.id]));
  const toReceive = lines.filter((l) => recvQty(l) > 0);
  const over = lines.some((l) => recvQty(l) > remaining(l));

  async function act(name: string, fn: string, args: Record<string, unknown>, done: string) {
    setBusy(name);
    setResult(null);
    try {
      await rpc(fn, args);
      setResult({ ok: true, text: done });
      setRecv({});
      setNotes('');
      setAllowOver(false);
    } catch (e) {
      setResult({ ok: false, text: errorMessage(e) });
    } finally {
      setBusy(null);
    }
  }

  function onScan(item: Item) {
    const line = lines.find((l) => l.item_id === item.id);
    if (!line) {
      setScanMsg(`${item.name} is not on ${po.po_no}.`);
      return;
    }
    // First scan of a line starts the count at 1; each further scan adds one purchase unit.
    const current = recv[line.id] === undefined ? 0 : Number(recv[line.id]);
    setRecv({ ...recv, [line.id]: String(current + 1) });
    setScanMsg(`Scanned ${item.name}: receiving ${current + 1} ${line.purchase_uom}.`);
  }

  const lastReceipt = receipts[receipts.length - 1];
  const daysLate = lastReceipt && po.expected_date ? dayDiff(po.expected_date, lastReceipt.received_at) : null;
  const ordered = lines.reduce((s, l) => s + Number(l.qty_ordered) * Number(l.unit_cost), 0);
  const received = lines.reduce((s, l) => s + Math.min(Number(l.qty_received), Number(l.qty_ordered)) * Number(l.unit_cost), 0);

  return (
    <div>
      <PageHeader
        title={`Purchase order ${po.po_no}`}
        subtitle={
          <>
            <Link to={`/suppliers/${supplier.id}`}>{supplier.name}</Link> · ship to {shipTo?.name ?? '?'} · {poSourceLabels[po.source] ?? po.source}
          </>
        }
        actions={<Link className="btn" to="/purchasing">All purchase orders</Link>}
      />

      <div className="steps-wrap">
        <ol className={`steps ${po.status}`}>
          <li className="done">
            <span className="step-label">Draft</span>
            <span className="muted small">{dateTime(po.created_at)}</span>
          </li>
          <li className={po.order_date ? 'done' : ''}>
            <span className="step-label">Order sent</span>
            <span className="muted small">{po.order_date ? dateTime(po.order_date) : 'Not yet'}</span>
            {po.expected_date && <span className="small">expected {date(po.expected_date)}</span>}
          </li>
          <li className={receipts.length ? 'done' : ''}>
            <span className="step-label">{po.status === 'partial' ? 'Partly received' : 'Received'}</span>
            <span className="muted small">{lastReceipt ? dateTime(lastReceipt.received_at) : 'Not yet'}</span>
            {daysLate !== null && (
              <span className={`small ${daysLate > 0 ? 'bad' : 'good'}`}>{daysLate > 0 ? `${daysLate} day${daysLate === 1 ? '' : 's'} late` : daysLate === 0 ? 'on time' : `${-daysLate} day${daysLate === -1 ? '' : 's'} early`}</span>
            )}
          </li>
          <li className={po.status === 'closed' || po.status === 'cancelled' ? 'done' : ''}>
            <span className="step-label">{po.status === 'cancelled' ? 'Cancelled' : 'Closed'}</span>
            <span className="muted small">{po.closed_at ? dateTime(po.closed_at) : 'Not yet'}</span>
          </li>
        </ol>
        <PoStatusBadge status={po.status} />
      </div>

      {po.status === 'draft' && (
        <div className="card action-card">
          <p className="muted">Sending fixes the expected receipt date: today + {supplier.quoted_lead_days} days quoted lead time.</p>
          <div className="page-actions">
            <button className="btn primary" disabled={busy !== null} onClick={() => act('send', 'send_purchase_order', { p_po_id: po.id }, `${po.po_no} sent to ${supplier.name}.`)}>
              {busy === 'send' ? 'Sending…' : 'Send to supplier'}
            </button>
            <button className="btn" disabled={busy !== null} onClick={() => act('cancel', 'cancel_purchase_order', { p_po_id: po.id }, `${po.po_no} cancelled.`)}>Cancel PO</button>
          </div>
        </div>
      )}

      {open && (
        <form
          className="card action-card"
          onSubmit={(e) => {
            e.preventDefault();
            void act(
              'receive',
              'receive_purchase_order',
              {
                p_po_id: po.id,
                p_lines: toReceive.map((l) => ({ po_line_id: l.id, qty: recvQty(l) })),
                p_location: receiveLoc,
                p_at: new Date(at).toISOString(),
                p_allow_over: allowOver,
                p_notes: notes.trim() || null,
              },
              `Received into ${data.locations.find((l) => l.id === receiveLoc)?.name}: stock is up and ${supplier.terms_days > 0 ? `a bill due in ${supplier.terms_days} days was added` : 'the supplier was paid'}.`,
            );
          }}
        >
          <h2 style={{ marginTop: 0 }}>Receive</h2>
          <p className="muted small">Scan each item's barcode (one scan = one {lines.length === 1 ? lines[0].purchase_uom : 'purchase unit'}), or type the quantities. Leave a line at 0 for a partial receipt.</p>
          <ScanItemInput items={lines.map((l) => l.item)} onPick={onScan} placeholder="Scan an item to receive it" />
          {scanMsg && <p className="small muted">{scanMsg}</p>}
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="num">Ordered</th>
                  <th className="num">Received so far</th>
                  <th className="num">Receive now</th>
                </tr>
              </thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.id}>
                    <td>{l.item.name}</td>
                    <td className="num">{qty(l.qty_ordered)} {l.purchase_uom}</td>
                    <td className="num">{qty(l.qty_received)}</td>
                    <td className="num">
                      <input className="qty-input" type="number" min={0} step="any" value={recv[l.id] ?? String(remaining(l))}
                        onChange={(e) => setRecv({ ...recv, [l.id]: e.target.value })} />
                      {recvQty(l) > remaining(l) && <div className="small bad">over by {qty(recvQty(l) - remaining(l))}</div>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="form-row">
            <label>
              Into location
              <select value={receiveLoc} onChange={(e) => setLoc(e.target.value)}>
                {data.locations.filter((l) => l.is_sellable).map((l) => (
                  <option key={l.id} value={l.id}>{l.name}</option>
                ))}
              </select>
            </label>
            <label>
              Received at
              <input type="datetime-local" value={at} onChange={(e) => setAt(e.target.value)} />
            </label>
            <label className="grow">
              Notes
              <input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Packing slip, damage…" />
            </label>
          </div>
          {over && (
            <label className="check">
              <input type="checkbox" checked={allowOver} onChange={(e) => setAllowOver(e.target.checked)} />
              The supplier sent more than ordered — accept the over-receipt
            </label>
          )}
          <div className="page-actions">
            <button className="btn primary" disabled={busy !== null || toReceive.length === 0 || (over && !allowOver)}>
              {busy === 'receive' ? 'Receiving…' : 'Record receipt'}
            </button>
            {po.status === 'partial' && (
              <button type="button" className="btn" disabled={busy !== null} onClick={() => act('close', 'close_purchase_order', { p_po_id: po.id }, `${po.po_no} closed short; the rest will not be delivered.`)}>
                Close short
              </button>
            )}
            {po.status === 'sent' && (
              <button type="button" className="btn" disabled={busy !== null} onClick={() => act('cancel', 'cancel_purchase_order', { p_po_id: po.id }, `${po.po_no} cancelled.`)}>
                Cancel PO
              </button>
            )}
          </div>
        </form>
      )}

      {po.status === 'received' && (
        <div className="card action-card">
          <p className="muted">Everything arrived. Close the PO once the paperwork is checked.</p>
          <div className="page-actions">
            <button className="btn primary" disabled={busy !== null} onClick={() => act('close', 'close_purchase_order', { p_po_id: po.id }, `${po.po_no} closed.`)}>
              {busy === 'close' ? 'Closing…' : 'Close PO'}
            </button>
          </div>
        </div>
      )}

      {result && <div className={`notice ${result.ok ? 'ok' : 'error'} spaced`}>{result.text}</div>}

      <div className="detail-grid">
        <div>
          <h2>Lines</h2>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="num">Ordered</th>
                  <th className="num">Received</th>
                  <th className="num">Unit cost</th>
                  <th className="num">Line total</th>
                  <th>Need by</th>
                </tr>
              </thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.id}>
                    <td>
                      <Link to={`/inventory/item/${l.item_id}`}>{l.item.name}</Link>
                      {Number(l.stock_per_purchase_unit) !== 1 && <div className="muted small">{qty(l.stock_per_purchase_unit, l.item.uom)} per {l.purchase_uom}</div>}
                    </td>
                    <td className="num">{qty(l.qty_ordered)} {l.purchase_uom}</td>
                    <td className={`num ${Number(l.qty_received) < Number(l.qty_ordered) && po.status === 'closed' ? 'bad' : ''}`}>{qty(l.qty_received)}</td>
                    <td className="num">{unitCost(l.unit_cost)}</td>
                    <td className="num">{money(Number(l.qty_ordered) * Number(l.unit_cost))}</td>
                    <td>{date(l.need_date)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan={4}>Ordered / received value</td>
                  <td className="num">{money(ordered)}</td>
                  <td className="small">{ordered > 0 ? `${((received / ordered) * 100).toFixed(0)}% filled` : ''}</td>
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
        <div>
          <h2>Dates and terms</h2>
          <dl className="facts">
            <dt>Sent</dt>
            <dd>{dateTime(po.order_date)}</dd>
            <dt>Quoted lead time</dt>
            <dd>{po.lead_days ?? supplier.quoted_lead_days} days</dd>
            <dt>Expected</dt>
            <dd>{date(po.expected_date)}</dd>
            <dt>Payment terms</dt>
            <dd>{po.terms_days > 0 ? `Net ${po.terms_days}` : 'Paid at purchase'}</dd>
            {po.notes && (
              <>
                <dt>Notes</dt>
                <dd>{po.notes}</dd>
              </>
            )}
          </dl>
          <h2>Receipts and bills</h2>
          {receipts.length === 0 ? (
            <p className="muted">Nothing received yet.</p>
          ) : (
            <ul className="activity">
              {receipts.map((r) => {
                const bill = data.bills.find((b) => b.receipt_id === r.id);
                const diff = po.expected_date ? dayDiff(po.expected_date, r.received_at) : null;
                const units = data.receiptLines.filter((x) => x.receipt_id === r.id).reduce((s, x) => s + Number(x.qty_received), 0);
                return (
                  <li key={r.id}>
                    <span className="muted small">
                      {dateTime(r.received_at)} · {data.locations.find((l) => l.id === r.location_id)?.name}
                      {diff !== null && <> · <span className={diff > 0 ? 'bad' : 'good'}>{diff > 0 ? `${diff} d late` : diff === 0 ? 'on time' : `${-diff} d early`}</span></>}
                    </span>
                    <span>
                      {qty(units)} unit{units === 1 ? '' : 's'} · bill {money(r.amount)}
                      {bill && (Number(bill.balance) > 0 ? <> · <strong>{money(bill.balance)} due {date(bill.due_date)}</strong>{bill.is_overdue && <span className="badge bad">Overdue</span>}</> : <> · paid</>)}
                      {r.notes && <span className="muted small"> · {r.notes}</span>}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      <JournalTables
        ledger={data.ledger}
        accounts={data.accounts}
        names={{ po_receipt: 'Receipt', supplier_payment: 'Supplier payment' }}
        empty="Nothing is posted until goods are received (Dr Inventory / Cr Accounts payable)."
      />
    </div>
  );
}
