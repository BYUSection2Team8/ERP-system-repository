import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import type { FulfillmentMethod, Item, PaymentMethod } from '../../lib/types';
import { ScanItemInput } from '../barcodes/ScanItemInput';
import { useInventoryData } from '../inventory/useInventoryData';
import {
  addToCart,
  CartTable,
  cartProblems,
  DiscountPicker,
  discountPayload,
  noDiscount,
  QuotePanel,
  useQuote,
  useSalesRefData,
  type CartLine,
  type DiscountChoice,
} from './salesShared';

/**
 * Create a sales order (status Order placed). Nothing leaves stock until the
 * order is fulfilled; lines that stock can't cover show up as backorders, and
 * the order's need date drives MRP.
 */
export function NewSalesOrderPage() {
  const navigate = useNavigate();
  const inv = useInventoryData();
  const ref = useSalesRefData();
  const [customerId, setCustomerId] = useState('');
  const [channel, setChannel] = useState<'online' | 'phone'>('online');
  const [method, setMethod] = useState<Exclude<FulfillmentMethod, 'counter'>>('ship');
  const [locationId, setLocationId] = useState('');
  const [shipState, setShipState] = useState('');
  const [needDate, setNeedDate] = useState('');
  const [payment, setPayment] = useState<PaymentMethod>('card');
  const [email, setEmail] = useState('');
  const [notes, setNotes] = useState('');
  const [lines, setLines] = useState<CartLine[]>([]);
  const [discount, setDiscount] = useState<DiscountChoice>(noDiscount);
  const [busy, setBusy] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const customer = ref.data?.customers.find((c) => c.id === customerId) ?? null;
  const locByCode = (code: string) => inv.data?.locations.find((l) => l.code === code)?.id ?? '';

  // Shipped orders leave from the Fulfillment Center; pickups are at the Campus Counter.
  useEffect(() => {
    if (inv.data) setLocationId(locByCode(method === 'ship' ? 'FULFILLMENT' : 'CAMPUS'));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inv.data === null, method]);

  // Customer defaults: ship-to state, email, on-account terms, BYU discount.
  useEffect(() => {
    if (!customer) return;
    setShipState(customer.state ?? '');
    setEmail(customer.email ?? '');
    setPayment(customer.terms_days > 0 ? 'account' : 'card');
    if (customer.is_byu && discount.type === 'none') setDiscount({ ...discount, type: 'byu' });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [customer?.id]);

  const sellable = useMemo(
    () => (inv.data?.items ?? []).filter((i: Item) => i.category === 'product' && i.price !== null),
    [inv.data],
  );

  const problems = cartProblems(lines);
  const payload =
    customerId && lines.length > 0 && problems.length === 0 && locationId
      ? {
          customer_id: customerId,
          channel,
          fulfillment_method: method,
          location_id: locationId,
          ship_state: method === 'ship' ? shipState.trim().toUpperCase() || null : null,
          need_date: needDate || null,
          payment_method: payment,
          customer_email: email.trim() || null,
          notes: notes.trim() || null,
          ...discountPayload(discount),
          lines: lines.map((l) => ({ item_id: l.item.id, qty: Number(l.qty) })),
        }
      : null;
  // Notes and email don't change the price: leave them out of the quote.
  const quotePayload = payload ? { ...payload, notes: null, customer_email: null } : null;
  const { quote, error: quoteError, pricing } = useQuote(quotePayload);

  if (inv.loading || ref.loading) return <Loading what="order form" />;
  if (inv.error || ref.error) return <ErrorNotice message={(inv.error ?? ref.error) as string} />;
  if (!inv.data || !ref.data) return null;
  const { locations, at } = inv.data;
  const { customers, discountReasons, settings } = ref.data;
  const available = (itemId: string) => Number(at(itemId, locationId)?.qty_available ?? 0);
  const backordered = lines.filter((l) => Number(l.qty) > available(l.item.id));

  async function save() {
    if (!payload) return;
    setBusy(true);
    setSaveError(null);
    try {
      const id = await rpc<string>('create_sales_order', { p: payload });
      navigate(`/sales/${id}`);
    } catch (e) {
      setSaveError(errorMessage(e));
      setBusy(false);
    }
  }

  return (
    <div>
      <PageHeader title="New sales order" subtitle="The order is saved as Order placed. Stock is taken when you fulfill it." />
      <div className="pos-grid">
        <div className="card form">
          <div className="form-row">
            <label className="grow">
              Customer
              <select value={customerId} onChange={(e) => setCustomerId(e.target.value)} autoFocus>
                <option value="">Choose a customer…</option>
                {customers.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name} · {c.customer_no}{c.city ? ` · ${c.city}, ${c.state ?? ''}` : ''}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Channel
              <select value={channel} onChange={(e) => setChannel(e.target.value as 'online' | 'phone')}>
                <option value="online">Online</option>
                <option value="phone">Phone</option>
              </select>
            </label>
          </div>
          {customer && (
            <div className="picked small">
              {customer.contact_name && <>{customer.contact_name} · </>}
              {customer.email ?? 'no email'}
              {customer.is_byu && <span className="badge ok">BYU student</span>}
              {customer.terms_days > 0 && <span className="badge">Net {customer.terms_days}</span>}
            </div>
          )}
          <div className="form-row">
            <label>
              Delivery
              <select value={method} onChange={(e) => setMethod(e.target.value as 'ship' | 'pickup')}>
                <option value="ship">Ship to customer</option>
                <option value="pickup">Customer picks up</option>
              </select>
            </label>
            <label className="grow">
              {method === 'ship' ? 'Ships from' : 'Pickup at'}
              <select value={locationId} onChange={(e) => setLocationId(e.target.value)}>
                {locations.filter((l) => l.is_sellable).map((l) => (
                  <option key={l.id} value={l.id}>{l.name}</option>
                ))}
              </select>
            </label>
            {method === 'ship' && (
              <label>
                Ship-to state
                <input value={shipState} maxLength={2} onChange={(e) => setShipState(e.target.value)} placeholder="UT" className="state-input" />
              </label>
            )}
            <label>
              Needed by
              <input type="date" value={needDate} onChange={(e) => setNeedDate(e.target.value)} />
            </label>
          </div>
          <label>
            Add items
            <ScanItemInput items={sellable} onPick={(item) => setLines((ls) => addToCart(ls, item))} />
          </label>
          <CartTable
            lines={lines}
            setLines={setLines}
            quote={quote}
            available={available}
            shortLabel="Short here: this line will be backordered."
          />
          {problems.length > 0 && <div className="notice warn">{problems.map((p) => <div key={p}>{p}</div>)}</div>}
          <div className="form-row">
            <label className="grow">
              Customer email (receipt)
              <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@example.com" />
            </label>
          </div>
          <label>
            Notes (optional)
            <textarea rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="e.g. Gift wrap, birthday on the 20th" />
          </label>
        </div>

        <div className="card form pos-pay">
          <DiscountPicker
            value={discount}
            onChange={setDiscount}
            settings={settings}
            reasons={discountReasons}
            units={quote?.units ?? lines.reduce((s, l) => s + (Number(l.qty) || 0), 0)}
            isByu={customer?.is_byu ?? false}
          />
          {!customerId ? (
            <p className="muted">Choose a customer to price the order.</p>
          ) : (
            <QuotePanel quote={quote} error={quoteError} pricing={pricing} reasons={discountReasons} />
          )}
          <label>
            Payment
            <select value={payment} onChange={(e) => setPayment(e.target.value as PaymentMethod)}>
              <option value="card">Card</option>
              <option value="cash">Cash</option>
              {customer && customer.terms_days > 0 && <option value="account">On account (Net {customer.terms_days})</option>}
            </select>
          </label>
          {backordered.length > 0 && (
            <div className="notice warn">
              {backordered.map((l) => l.item.name).join(', ')} {backordered.length === 1 ? 'is' : 'are'} short at this location.
              The order can still be placed; it waits as a backorder until stock arrives.
            </div>
          )}
          {saveError && <div className="notice error">{saveError}</div>}
          <button className="btn primary big" disabled={busy || !quote || pricing} onClick={save}>
            {busy ? 'Placing order…' : 'Place order'}
          </button>
        </div>
      </div>
    </div>
  );
}
