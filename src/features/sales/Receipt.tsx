import { Link, useParams } from 'react-router-dom';
import { ErrorNotice, Loading } from '../../app/ui';
import { dateTime, money, qty } from '../../lib/format';
import { Barcode } from '../barcodes/Barcode';
import { methodLabels, paymentLabels, TotalsTable, useSalesRefData } from './salesShared';
import { useOrder, type OrderView } from './useOrder';
import { QrCode } from '../tracking/QrCode';
import { trackingUrl } from '../tracking/tracking';

/** Printable receipt built only from the saved order (not from the screen). */
export function Receipt({ view, companyName, returnDays }: { view: OrderView; companyName: string; returnDays: number }) {
  const { order, lines, customer, location, reasonText, cashier } = view;
  const isPos = order.channel === 'pos';
  return (
    <div className="receipt print-area">
      <div className="receipt-head">
        <div className="receipt-company">{companyName}</div>
        <div>{location.name}</div>
        <div className="muted small">{isPos ? 'Sales receipt' : `Order ${order.status === 'placed' ? 'confirmation' : 'receipt'}`}</div>
      </div>
      <dl className="receipt-facts">
        <dt>Order</dt>
        <dd>{order.order_no}</dd>
        <dt>Date</dt>
        <dd>{dateTime(order.order_date)}</dd>
        {customer && (
          <>
            <dt>Customer</dt>
            <dd>{customer.name}</dd>
          </>
        )}
        {!isPos && (
          <>
            <dt>Delivery</dt>
            <dd>{methodLabels[order.fulfillment_method]}{order.ship_state ? ` (${order.ship_state})` : ''}</dd>
          </>
        )}
        {cashier && (
          <>
            <dt>Served by</dt>
            <dd>{cashier}</dd>
          </>
        )}
      </dl>
      <table className="receipt-lines">
        <tbody>
          {lines.map((l) => (
            <tr key={l.id}>
              <td>
                {l.item.name}
                <div className="small muted">
                  {qty(l.qty, l.item.uom)} × {money(l.unit_price)}
                </div>
              </td>
              <td className="num">{money(l.line_total)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <TotalsTable t={order} reasonText={reasonText} />
      <div className="receipt-pay">
        Paid by: {order.payment_method ? paymentLabels[order.payment_method] : '—'}
        {order.payment_method === 'account' && customer?.terms_days ? ` (Net ${customer.terms_days})` : ''}
      </div>
      <div className="receipt-barcode">
        <Barcode value={order.order_no} height={36} moduleWidth={1.4} />
      </div>
      {order.tracking_token && order.status !== 'cancelled' && (
        <div className="receipt-qr">
          <QrCode value={trackingUrl(order.tracking_token)} size={92} label="QR code to track this order" />
          <div className="small">Scan to track your order{order.fulfillment_method === 'counter' ? '' : ' live'}</div>
        </div>
      )}
      <p className="receipt-foot small">
        Returns accepted within {returnDays} days with this receipt. Thank you for supporting a BYU student business!
      </p>
    </div>
  );
}

/** /sales/:id/receipt — receipt on its own page, ready to print. */
export function ReceiptPage() {
  const { id = '' } = useParams();
  const { data, error, loading } = useOrder(id);
  const ref = useSalesRefData();
  if (loading || ref.loading) return <Loading what="receipt" />;
  if (error || ref.error) return <ErrorNotice message={(error ?? ref.error) as string} />;
  if (!data || !ref.data) return null;
  return (
    <div>
      <div className="page-actions no-print receipt-actions">
        <button className="btn primary" onClick={() => window.print()}>Print receipt</button>
        <Link className="btn" to={`/sales/${id}`}>Back to order</Link>
      </div>
      <Receipt view={data} companyName={ref.data.settings.companyName} returnDays={ref.data.settings.returnDays} />
    </div>
  );
}
