import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import { date, dateTime, money, qty, unitCost } from '../../lib/format';
import type { LedgerRow } from '../../lib/types';
import { channelLabels, methodLabels, paymentLabels, StatusBadge, TotalsTable } from './salesShared';
import { useOrder, type OrderView } from './useOrder';

const journalNames: Record<string, string> = {
  sale: 'Sale (fulfillment)',
  customer_payment: 'Customer payment',
};

export function SalesOrderDetailPage() {
  const { id = '' } = useParams();
  const { data, error, loading } = useOrder(id);
  const [busy, setBusy] = useState<string | null>(null);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [cancelReason, setCancelReason] = useState('');

  if (loading) return <Loading what="order" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const { order, lines, customer, location, backorders, returns } = data;

  async function act(name: string, fn: string, args: Record<string, unknown>, done: string) {
    setBusy(name);
    setResult(null);
    try {
      await rpc(fn, args);
      setResult({ ok: true, text: done });
      setCancelling(false);
    } catch (e) {
      setResult({ ok: false, text: errorMessage(e) });
    } finally {
      setBusy(null);
    }
  }

  const short = order.status === 'placed' ? lines.filter((l) => Number(l.qty) - Number(l.qty_fulfilled) > (data.stock.get(l.item_id)?.on_hand ?? 0)) : [];
  const isAccount = order.payment_method === 'account';

  return (
    <div>
      <PageHeader
        title={`Sales order ${order.order_no}`}
        subtitle={
          <>
            {customer ? <>{customer.name} · </> : 'Walk-in customer · '}
            {channelLabels[order.channel]} · {methodLabels[order.fulfillment_method]} · {location.name}
          </>
        }
        actions={
          <>
            {(order.status === 'fulfilled' || order.status === 'closed') && (
              <Link className="btn" to={`/returns/new?so=${order.id}`}>Return / exchange</Link>
            )}
            <Link className="btn" to={`/sales/${order.id}/receipt`}>{order.status === 'placed' ? 'Print confirmation' : 'Print receipt'}</Link>
            <Link className="btn" to="/sales">All orders</Link>
          </>
        }
      />

      <StatusSteps view={data} />

      {order.status === 'placed' && (
        <div className="card action-card">
          {short.length > 0 ? (
            <div className="notice warn">
              <strong>Backordered.</strong> {location.name} is short:{' '}
              {short
                .map((l) => {
                  const b = backorders.find((x) => x.so_line_id === l.id);
                  return `${l.item.name} (needs ${qty(Number(l.qty) - Number(l.qty_fulfilled), l.item.uom)}, has ${qty(data.stock.get(l.item_id)?.on_hand ?? 0, l.item.uom)}${b?.est_available_date ? `, est. ${date(b.est_available_date)}` : ''})`;
                })
                .join('; ')}
              . Fulfill when stock arrives, or <Link to="/inventory/transfer">transfer stock</Link> here.
            </div>
          ) : (
            <p className="muted">All lines are in stock at {location.name}. Fulfilling takes the stock out and posts the sale to the ledger.</p>
          )}
          <div className="page-actions">
            <button
              className="btn primary"
              disabled={busy !== null || short.length > 0}
              onClick={() => act('fulfill', 'fulfill_sales_order', { p_so_id: order.id }, `${order.order_no} fulfilled: stock taken and the sale posted.`)}
            >
              {busy === 'fulfill' ? 'Fulfilling…' : order.fulfillment_method === 'ship' ? 'Fulfill (ship)' : 'Fulfill (hand over)'}
            </button>
            {!cancelling ? (
              <button className="btn" disabled={busy !== null} onClick={() => setCancelling(true)}>Cancel order…</button>
            ) : (
              <form
                className="inline-form"
                onSubmit={(e) => {
                  e.preventDefault();
                  void act('cancel', 'cancel_sales_order', { p_so_id: order.id, p_reason: cancelReason.trim() || null }, `${order.order_no} cancelled.`);
                }}
              >
                <input value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="Reason (e.g. customer changed plans)" autoFocus />
                <button className="btn danger" disabled={busy !== null}>{busy === 'cancel' ? 'Cancelling…' : 'Confirm cancel'}</button>
                <button type="button" className="btn link" onClick={() => setCancelling(false)}>Keep order</button>
              </form>
            )}
          </div>
        </div>
      )}

      {order.status === 'fulfilled' && (
        <div className="card action-card">
          <p className="muted">
            {isAccount
              ? `Billed on account (Net ${customer?.terms_days ?? 30}): closing records the customer's payment (Cash up, Accounts receivable down).`
              : 'Paid at purchase. Closing marks the order done.'}
          </p>
          <div className="page-actions">
            <button
              className="btn primary"
              disabled={busy !== null}
              onClick={() => act('close', 'close_sales_order', { p_so_id: order.id }, `${order.order_no} closed.`)}
            >
              {busy === 'close' ? 'Closing…' : isAccount ? 'Record payment & close' : 'Close order'}
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
                  <th className="num">Qty</th>
                  <th className="num">Price</th>
                  <th className="num">Net price</th>
                  <th className="num">Line total</th>
                  {order.status === 'placed' ? <th className="num">On hand here</th> : <th className="num">Unit cost (COGS)</th>}
                </tr>
              </thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.id}>
                    <td>
                      <Link to={`/inventory/item/${l.item_id}`}>{l.item.name}</Link>
                      <div className="muted small">{l.item.sku}{Number(l.qty_returned) > 0 && ` · ${qty(l.qty_returned)} returned`}</div>
                    </td>
                    <td className="num">{qty(l.qty, l.item.uom)}</td>
                    <td className="num">{money(l.unit_price)}</td>
                    <td className="num">{unitCost(l.net_unit_price)}</td>
                    <td className="num">{money(l.line_total)}</td>
                    {order.status === 'placed' ? (
                      <td className={`num ${short.some((s) => s.id === l.id) ? 'bad strong' : ''}`}>{qty(data.stock.get(l.item_id)?.on_hand ?? 0, l.item.uom)}</td>
                    ) : (
                      <td className="num">{l.unit_cost === null ? '—' : unitCost(l.unit_cost)}</td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {order.status !== 'placed' && order.status !== 'cancelled' && (
            <p className="muted small">Unit cost is the weighted-average cost when the stock left; it is what COGS was charged.</p>
          )}
        </div>
        <div>
          <h2>Totals</h2>
          <div className="card">
            <TotalsTable t={order} reasonText={data.reasonText} />
          </div>
          <dl className="facts">
            <dt>Ordered</dt>
            <dd>{dateTime(order.order_date)}</dd>
            {order.need_date && order.status === 'placed' && (
              <>
                <dt>Needed by</dt>
                <dd>{date(order.need_date)}</dd>
              </>
            )}
            <dt>Payment</dt>
            <dd>{order.payment_method ? paymentLabels[order.payment_method] : '—'}</dd>
            {order.customer_email && (
              <>
                <dt>Email</dt>
                <dd>{order.customer_email}</dd>
              </>
            )}
            {order.notes && (
              <>
                <dt>Notes</dt>
                <dd>{order.notes}</dd>
              </>
            )}
            {data.cashier && (
              <>
                <dt>Entered by</dt>
                <dd>{data.cashier}</dd>
              </>
            )}
          </dl>
        </div>
      </div>

      {returns.length > 0 && (
        <>
          <h2>Returns & exchanges</h2>
          <ul className="activity">
            {returns.map((r) => (
              <li key={r.id}>
                <span className="muted small">{dateTime(r.returned_at)}</span>
                <span>
                  {r.return_no}: {r.return_type === 'exchange' ? 'Exchange' : 'Refund'} {money(r.refund_amount)}
                  {r.exchange_so_id && <> · <Link to={`/sales/${r.exchange_so_id}`}>replacement order</Link></>}
                </span>
              </li>
            ))}
          </ul>
        </>
      )}

      <Accounting view={data} />
    </div>
  );
}

function StatusSteps({ view }: { view: OrderView }) {
  const { order } = view;
  const backordered = view.backorders.length > 0;
  const steps: { label: string; at: string | null; done: boolean; note?: string | null }[] =
    order.status === 'cancelled'
      ? [
          { label: 'Order placed', at: order.order_date, done: true },
          { label: 'Cancelled', at: order.cancelled_at, done: true, note: order.cancel_reason },
        ]
      : [
          { label: 'Order placed', at: order.order_date, done: true },
          { label: 'Fulfilled', at: order.fulfilled_at, done: order.fulfilled_at !== null },
          { label: 'Closed', at: order.closed_at, done: order.closed_at !== null },
        ];
  return (
    <div className="steps-wrap">
      <ol className={`steps ${order.status}`}>
        {steps.map((s) => (
          <li key={s.label} className={s.done ? 'done' : ''}>
            <span className="step-label">{s.label}</span>
            <span className="muted small">{s.done ? dateTime(s.at) : 'Not yet'}</span>
            {s.note && <span className="small">{s.note}</span>}
          </li>
        ))}
      </ol>
      <StatusBadge status={order.status} backordered={backordered} />
    </div>
  );
}

/** Journal entries this order posted: shows how a sale hits the books. */
function Accounting({ view }: { view: OrderView }) {
  const { ledger, accounts, order } = view;
  if (ledger.length === 0) {
    return (
      <>
        <h2>Accounting</h2>
        <p className="muted">
          {order.status === 'cancelled'
            ? 'Cancelled before fulfillment: nothing was posted.'
            : 'Nothing is posted until the order is fulfilled. Placed orders only reserve demand (they show as committed stock and feed MRP).'}
        </p>
      </>
    );
  }
  const journals = new Map<string, LedgerRow[]>();
  for (const r of ledger) journals.set(r.journal_id, [...(journals.get(r.journal_id) ?? []), r]);
  return (
    <>
      <h2>Accounting (journal entries)</h2>
      <p className="muted small">
        Posted by the database when the order changed status. Debits always equal credits. Returns post their own entries.
      </p>
      {[...journals.values()].map((rows) => {
        const dr = rows.reduce((s, r) => s + Number(r.debit), 0);
        const cr = rows.reduce((s, r) => s + Number(r.credit), 0);
        return (
          <div className="table-wrap journal" key={rows[0].journal_id}>
            <table className="table">
              <thead>
                <tr>
                  <th>{journalNames[rows[0].source_type] ?? rows[0].source_type} · {dateTime(rows[0].posted_at)}</th>
                  <th className="num">Debit</th>
                  <th className="num">Credit</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id}>
                    <td className={Number(r.credit) > 0 ? 'indent' : ''}>
                      {r.account_code} {accounts.get(r.account_code)?.name ?? ''}
                    </td>
                    <td className="num">{Number(r.debit) > 0 ? money(r.debit) : ''}</td>
                    <td className="num">{Number(r.credit) > 0 ? money(r.credit) : ''}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td>Total</td>
                  <td className="num">{money(dr)}</td>
                  <td className="num">{money(cr)}</td>
                </tr>
              </tfoot>
            </table>
          </div>
        );
      })}
    </>
  );
}
