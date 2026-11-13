import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { date, money, qty, unitCost } from '../../lib/format';
import type { Item, Location, ReasonCode, ReturnQuote, SalesOrder, SalesOrderLine } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { ScanItemInput } from '../barcodes/ScanItemInput';

interface LineView extends SalesOrderLine {
  item: Item;
}
interface Choice {
  qty: string;
  reason: string;
  location: string;
}

async function loadRef() {
  const c = db();
  const [reasons, locations, products, settings] = await Promise.all([
    c.from('reason_codes').select('*').eq('category', 'return').eq('is_active', true).order('sort_order').then(unwrap<(ReasonCode & { charges_restocking_fee: boolean })[]>),
    c.from('locations').select('*').eq('is_active', true).order('sort_order').then(unwrap<Location[]>),
    c.from('items').select('*').eq('is_active', true).eq('category', 'product').not('price', 'is', null).order('name').then(unwrap<Item[]>),
    c.from('settings').select('key, value').in('key', ['return_window_days', 'restocking_fee_pct']).then(unwrap<{ key: string; value: string }[]>),
  ]);
  const s = new Map(settings.map((x) => [x.key, Number(x.value)]));
  return { reasons, locations, products, windowDays: s.get('return_window_days') ?? 30, feePct: s.get('restocking_fee_pct') ?? 0.1 };
}

async function loadOrder(soId: string) {
  if (!soId) return null;
  const c = db();
  const order = await c.from('sales_orders').select('*').eq('id', soId).maybeSingle().then(unwrap<SalesOrder | null>);
  if (!order) throw new Error('That sales order does not exist.');
  const [lines, customer] = await Promise.all([
    c.from('sales_order_lines').select('*, item:items(*)').eq('so_id', soId).order('line_no').then((r) => unwrap(r) as unknown as LineView[]),
    order.customer_id ? c.from('customers').select('name').eq('id', order.customer_id).maybeSingle().then(unwrap<{ name: string } | null>) : Promise.resolve(null),
  ]);
  return { order, lines, customerName: customer?.name ?? null };
}

const refundTo: Record<string, string> = {
  card: 'back to the card',
  cash: 'in cash',
  account: "off the customer's account (A/R)",
  exchange: 'as store credit',
};

export function NewReturnPage() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const [soId, setSoId] = useState(params.get('so') ?? '');
  const [orderNo, setOrderNo] = useState('');
  const [findErr, setFindErr] = useState<string | null>(null);
  const ref = useLiveQuery(loadRef, ['reason_codes', 'items', 'settings']);
  const ord = useLiveQuery(() => loadOrder(soId), ['sales_orders', 'sales_order_lines', 'returns'], [soId]);

  const [choices, setChoices] = useState<Record<string, Choice>>({});
  const [mode, setMode] = useState<'refund' | 'exchange'>('refund');
  const [exchange, setExchange] = useState<{ item: Item; qty: number }[]>([]);
  const [notes, setNotes] = useState('');
  const [quote, setQuote] = useState<ReturnQuote | null>(null);
  const [quoteErr, setQuoteErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // Reset choices when the order changes.
  useEffect(() => {
    setChoices({});
    setExchange([]);
    setQuote(null);
  }, [soId]);

  const o = ord.data;
  const payload = useMemo(() => {
    if (!o) return null;
    const lines = o.lines.flatMap((l) => {
      const c = choices[l.id];
      if (!c || !(Number(c.qty) > 0) || !c.reason) return [];
      return [{ so_line_id: l.id, qty: Number(c.qty), reason_code: c.reason, location_id: c.location || o.order.location_id }];
    });
    if (lines.length === 0) return null;
    const p: Record<string, unknown> = { so_id: o.order.id, lines, notes: notes.trim() || null };
    if (mode === 'exchange' && exchange.length > 0) p.exchange_lines = exchange.map((x) => ({ item_id: x.item.id, qty: x.qty }));
    return p;
  }, [o, choices, mode, exchange, notes]);

  // Live preview from the database (quote_return runs the real return and undoes it).
  const key = JSON.stringify(payload);
  useEffect(() => {
    if (!payload) {
      setQuote(null);
      setQuoteErr(null);
      return;
    }
    const t = window.setTimeout(async () => {
      try {
        setQuote(await rpc<ReturnQuote>('quote_return', { p: payload }));
        setQuoteErr(null);
      } catch (e) {
        setQuote(null);
        setQuoteErr(errorMessage(e));
      }
    }, 300);
    return () => window.clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  async function find() {
    setFindErr(null);
    const no = orderNo.trim().toUpperCase();
    if (!no) return;
    try {
      const row = await db().from('sales_orders').select('id').eq('order_no', no.startsWith('SO-') ? no : `SO-${no}`).maybeSingle().then(unwrap<{ id: string } | null>);
      if (!row) setFindErr(`No order ${no}.`);
      else setSoId(row.id);
    } catch (e) {
      setFindErr(errorMessage(e));
    }
  }

  async function submit() {
    if (!payload) return;
    setBusy(true);
    setErr(null);
    try {
      const id = await rpc<string>('process_return', { p: payload });
      navigate(`/returns/${id}`);
    } catch (e) {
      setErr(errorMessage(e));
      setBusy(false);
    }
  }

  if (ref.loading) return <Loading what="return reasons" />;
  if (ref.error) return <ErrorNotice message={ref.error} />;
  const r = ref.data!;
  const reasonOf = (code: string) => r.reasons.find((x) => x.code === code);

  const deadline = o?.order.fulfilled_at ? new Date(new Date(o.order.fulfilled_at).getTime() + r.windowDays * 86400000) : null;
  const returnable = o && (o.order.status === 'fulfilled' || o.order.status === 'closed');

  return (
    <div>
      <PageHeader
        title="New return or exchange"
        subtitle={`Returns are accepted within ${r.windowDays} days of fulfillment. Quality failures go to QA Hold; changed-mind refunds of made-to-order items pay a ${(r.feePct * 100).toFixed(0)}% restocking fee.`}
        actions={<Link className="btn" to="/returns">All returns</Link>}
      />

      <form className="toolbar" onSubmit={(e) => { e.preventDefault(); void find(); }}>
        <input value={orderNo} onChange={(e) => setOrderNo(e.target.value)} placeholder="Order number, e.g. SO-10234 (or scan the receipt barcode)" aria-label="Order number" className="grow" />
        <button className="btn">Find order</button>
      </form>
      {findErr && <ErrorNotice message={findErr} />}

      {ord.loading && soId && <Loading what="order" />}
      {ord.error && <ErrorNotice message={ord.error} />}

      {o && (
        <>
          <div className="card">
            <strong><Link to={`/sales/${o.order.id}`}>{o.order.order_no}</Link></strong> · {o.customerName ?? 'Walk-in customer'} · fulfilled {date(o.order.fulfilled_at)} · paid by {o.order.payment_method ?? '—'}
            {deadline && <div className={`small ${deadline < new Date() ? 'bad' : 'muted'}`}>Return window ends {date(deadline.toISOString())}{deadline < new Date() ? ' — past the window' : ''}</div>}
            {!returnable && <div className="notice warn spaced">This order is {o.order.status}; only fulfilled or closed orders can be returned.</div>}
          </div>

          {returnable && (
            <>
              <h2>Items coming back</h2>
              <div className="table-wrap">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Item</th>
                      <th className="num">Sold</th>
                      <th className="num">Can return</th>
                      <th className="num">Net price</th>
                      <th className="num">Return qty</th>
                      <th>Reason</th>
                      <th>Goes to</th>
                    </tr>
                  </thead>
                  <tbody>
                    {o.lines.map((l) => {
                      const can = Number(l.qty_fulfilled) - Number(l.qty_returned);
                      const c = choices[l.id] ?? { qty: '0', reason: '', location: '' };
                      const set = (patch: Partial<Choice>) => setChoices({ ...choices, [l.id]: { ...c, ...patch } });
                      const quality = reasonOf(c.reason)?.is_quality;
                      return (
                        <tr key={l.id}>
                          <td>{l.item.name}<div className="muted small">{l.item.sku}{l.item.stocking_policy === 'make_to_order' ? ' · made to order' : ''}</div></td>
                          <td className="num">{qty(l.qty_fulfilled)}</td>
                          <td className="num">{qty(can)}</td>
                          <td className="num">{unitCost(l.net_unit_price)}</td>
                          <td className="num">
                            <input className="qty-input" type="number" min={0} max={can} step={1} value={c.qty} disabled={can <= 0} onChange={(e) => set({ qty: e.target.value })} />
                          </td>
                          <td>
                            <select value={c.reason} onChange={(e) => set({ reason: e.target.value })} disabled={can <= 0}>
                              <option value="">Choose a reason…</option>
                              {r.reasons.map((x) => (
                                <option key={x.code} value={x.code}>{x.description}{x.is_quality ? ' (quality)' : ''}</option>
                              ))}
                            </select>
                          </td>
                          <td>
                            {quality ? (
                              <span className="badge warn status">QA Hold</span>
                            ) : (
                              <select value={c.location || o.order.location_id} onChange={(e) => set({ location: e.target.value })} disabled={can <= 0}>
                                {r.locations.filter((x) => x.is_sellable).map((x) => (
                                  <option key={x.id} value={x.id}>{x.name}</option>
                                ))}
                              </select>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>

              <h2>Refund or exchange</h2>
              <div className="choice-row">
                <label className="check"><input type="radio" checked={mode === 'refund'} onChange={() => setMode('refund')} /> Refund</label>
                <label className="check"><input type="radio" checked={mode === 'exchange'} onChange={() => setMode('exchange')} /> Exchange for other items (same discount, no shipping charge, no restocking fee)</label>
              </div>
              {mode === 'exchange' && (
                <div className="card spaced">
                  <ScanItemInput items={r.products} onPick={(item) => {
                    const found = exchange.find((x) => x.item.id === item.id);
                    setExchange(found ? exchange.map((x) => (x.item.id === item.id ? { ...x, qty: x.qty + 1 } : x)) : [...exchange, { item, qty: 1 }]);
                  }} placeholder="Scan or search the replacement item" />
                  {exchange.length > 0 && (
                    <table className="table">
                      <tbody>
                        {exchange.map((x) => (
                          <tr key={x.item.id}>
                            <td>{x.item.name}</td>
                            <td className="num">
                              <input className="qty-input" type="number" min={1} step={1} value={x.qty}
                                onChange={(e) => setExchange(exchange.map((y) => (y.item.id === x.item.id ? { ...y, qty: Math.max(1, Math.round(Number(e.target.value) || 1)) } : y)))} />
                            </td>
                            <td><button type="button" className="btn link" onClick={() => setExchange(exchange.filter((y) => y.item.id !== x.item.id))}>Remove</button></td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  )}
                </div>
              )}

              <label className="spaced">
                Notes
                <input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Optional (e.g. crack along the wing)" />
              </label>

              <h2>Preview</h2>
              {!payload ? (
                <p className="muted">Enter a quantity and a reason for at least one item.</p>
              ) : quoteErr ? (
                <ErrorNotice message={quoteErr} />
              ) : !quote ? (
                <Loading what="preview" />
              ) : (
                <div className="card">
                  <table className="totals">
                    <tbody>
                      <tr><td>Merchandise credit (net price paid)</td><td className="num">{money(quote.merchandise_credit)}</td></tr>
                      <tr><td>Sales tax refunded</td><td className="num">{money(quote.tax_credit)}</td></tr>
                      {Number(quote.restocking_fee) > 0 && <tr><td>Restocking fee</td><td className="num bad">−{money(quote.restocking_fee)}</td></tr>}
                      {quote.exchange && (
                        <tr>
                          <td>Replacement order{quote.exchange.will_ship_now ? '' : ' (backordered: ships when made)'}</td>
                          <td className="num">−{money(quote.exchange.total)}</td>
                        </tr>
                      )}
                      <tr className="grand">
                        <td>{Number(quote.refund_amount) >= 0 ? `Refund ${refundTo[quote.refund_to] ?? ''}` : 'Customer pays the difference'}</td>
                        <td className="num">{money(Math.abs(Number(quote.refund_amount)))}</td>
                      </tr>
                    </tbody>
                  </table>
                  <p className="muted small">
                    {quote.lines.map((l) => {
                      const item = o.lines.find((x) => x.id === l.so_line_id)?.item;
                      return `${qty(l.qty)} × ${item?.name} → ${l.disposition === 'qa_hold' ? 'QA Hold' : r.locations.find((x) => x.id === l.location_id)?.name} at cost ${unitCost(l.unit_cost)}`;
                    }).join('; ')}. The ledger reverses the sale: Dr Sales returns + Dr Sales tax, Cr Cash/A/R{Number(quote.restocking_fee) > 0 ? ' + Cr Restocking fees' : ''}; Dr Inventory / Cr COGS.
                  </p>
                </div>
              )}

              {err && <ErrorNotice message={err} />}
              <div className="page-actions spaced">
                <button className="btn primary" disabled={!payload || !quote || busy || (mode === 'exchange' && exchange.length === 0)} onClick={submit}>
                  {busy ? 'Processing…' : mode === 'exchange' ? 'Process exchange' : 'Process refund'}
                </button>
              </div>
            </>
          )}
        </>
      )}
    </div>
  );
}
