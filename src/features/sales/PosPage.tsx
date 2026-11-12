import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import { money } from '../../lib/format';
import type { Item } from '../../lib/types';
import { ScanItemInput } from '../barcodes/ScanItemInput';
import { useInventoryData } from '../inventory/useInventoryData';
import { Receipt } from './Receipt';
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
import { useOrder } from './useOrder';

/**
 * Point of sale (Campus Counter by default). One click runs pos_sale, which
 * creates, fulfills and closes the order in a single database transaction:
 * stock goes down, revenue / discount / tax / COGS are posted to the ledger.
 */
export function PosPage() {
  const inv = useInventoryData();
  const ref = useSalesRefData();
  const [locationId, setLocationId] = useState('');
  const [customerId, setCustomerId] = useState('');
  const [lines, setLines] = useState<CartLine[]>([]);
  const [discount, setDiscount] = useState<DiscountChoice>(noDiscount);
  const [payment, setPayment] = useState<'card' | 'cash'>('card');
  const [tendered, setTendered] = useState('');
  const [busy, setBusy] = useState(false);
  const [saleError, setSaleError] = useState<string | null>(null);
  const [doneId, setDoneId] = useState<string | null>(null);

  useEffect(() => {
    if (inv.data && !locationId) setLocationId(inv.data.locations.find((l) => l.code === 'CAMPUS')?.id ?? '');
  }, [inv.data, locationId]);

  const sellable = useMemo(
    () => (inv.data?.items ?? []).filter((i: Item) => i.category === 'product' && i.price !== null),
    [inv.data],
  );
  const customer = ref.data?.customers.find((c) => c.id === customerId) ?? null;

  // When a BYU customer is chosen and no discount is picked, apply the BYU discount.
  useEffect(() => {
    if (customer?.is_byu && discount.type === 'none') setDiscount({ ...discount, type: 'byu' });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [customer?.id]);

  const problems = cartProblems(lines);
  const payload =
    lines.length > 0 && problems.length === 0 && locationId
      ? {
          channel: 'pos',
          fulfillment_method: 'counter',
          location_id: locationId,
          customer_id: customerId || null,
          payment_method: payment,
          ...discountPayload(discount),
          lines: lines.map((l) => ({ item_id: l.item.id, qty: Number(l.qty) })),
        }
      : null;
  const { quote, error: quoteError, pricing } = useQuote(payload);

  if (inv.loading || ref.loading) return <Loading what="point of sale" />;
  if (inv.error || ref.error) return <ErrorNotice message={(inv.error ?? ref.error) as string} />;
  if (!inv.data || !ref.data) return null;
  const { locations, at } = inv.data;
  const { customers, discountReasons, settings } = ref.data;

  const available = (itemId: string) => Number(at(itemId, locationId)?.qty_available ?? 0);
  const shortages = lines.filter((l) => Number(l.qty) > available(l.item.id));
  const change = quote && payment === 'cash' && tendered !== '' ? Number(tendered) - Number(quote.total) : null;

  function reset() {
    setLines([]);
    setCustomerId('');
    setDiscount(noDiscount);
    setPayment('card');
    setTendered('');
    setSaleError(null);
    setDoneId(null);
  }

  async function completeSale() {
    if (!payload) return;
    setBusy(true);
    setSaleError(null);
    try {
      const id = await rpc<string>('pos_sale', { p: payload });
      setDoneId(id);
    } catch (e) {
      setSaleError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  if (doneId) {
    return <PosDone id={doneId} change={change} onNewSale={reset} companyName={settings.companyName} returnDays={settings.returnDays} />;
  }

  return (
    <div>
      <PageHeader
        title="Point of sale"
        subtitle="Scan items to add them. Completing the sale takes the stock out of this location and posts revenue, discount, sales tax and cost of goods sold."
      />
      <div className="pos-grid">
        <div className="card form pos-cart">
          <div className="form-row">
            <label className="grow">
              Selling from
              <select value={locationId} onChange={(e) => setLocationId(e.target.value)}>
                {locations.filter((l) => l.is_sellable).map((l) => (
                  <option key={l.id} value={l.id}>{l.name}</option>
                ))}
              </select>
            </label>
            <label className="grow">
              Customer (optional)
              <select value={customerId} onChange={(e) => setCustomerId(e.target.value)}>
                <option value="">Walk-in customer</option>
                {customers.map((c) => (
                  <option key={c.id} value={c.id}>{c.name}{c.is_byu ? ' (BYU)' : ''}</option>
                ))}
              </select>
            </label>
          </div>
          <label>
            Scan or search
            <ScanItemInput items={sellable} onPick={(item) => { setSaleError(null); setLines((ls) => addToCart(ls, item)); }} autoFocus />
          </label>
          <CartTable
            lines={lines}
            setLines={setLines}
            quote={quote}
            available={available}
            shortLabel="Not enough here. Transfer stock or use a sales order."
          />
          {problems.length > 0 && <div className="notice warn">{problems.map((p) => <div key={p}>{p}</div>)}</div>}
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
          <QuotePanel quote={quote} error={quoteError} pricing={pricing} reasons={discountReasons} />
          <fieldset className="discount">
            <legend>Payment</legend>
            <div className="choice-row">
              <label className="check">
                <input type="radio" checked={payment === 'card'} onChange={() => setPayment('card')} /> Card
              </label>
              <label className="check">
                <input type="radio" checked={payment === 'cash'} onChange={() => setPayment('cash')} /> Cash
              </label>
            </div>
            {payment === 'cash' && (
              <div className="form-row">
                <label>
                  Cash received
                  <input type="number" min="0" step="0.01" value={tendered} onChange={(e) => setTendered(e.target.value)} placeholder="0.00" />
                </label>
                {change !== null && (
                  <div className={`change ${change < 0 ? 'bad' : ''}`}>
                    {change < 0 ? `Still owed ${money(-change)}` : `Change due ${money(change)}`}
                  </div>
                )}
              </div>
            )}
          </fieldset>
          {shortages.length > 0 && (
            <div className="notice warn">
              Not enough stock at this location for {shortages.map((l) => l.item.name).join(', ')}.{' '}
              <Link to="/inventory/transfer">Transfer stock</Link> or <Link to="/sales/new">create a sales order</Link> (it will be backordered).
            </div>
          )}
          {saleError && <div className="notice error">{saleError}</div>}
          <button
            className="btn primary big"
            disabled={busy || !quote || pricing || shortages.length > 0 || (change !== null && change < 0)}
            onClick={completeSale}
          >
            {busy ? 'Completing sale…' : quote ? `Complete sale · ${money(quote.total)}` : 'Complete sale'}
          </button>
          {lines.length > 0 && (
            <button type="button" className="btn link" onClick={reset}>Clear sale</button>
          )}
        </div>
      </div>
    </div>
  );
}

function PosDone({
  id,
  change,
  onNewSale,
  companyName,
  returnDays,
}: {
  id: string;
  change: number | null;
  onNewSale: () => void;
  companyName: string;
  returnDays: number;
}) {
  const { data, error, loading } = useOrder(id);
  return (
    <div>
      <PageHeader
        title="Sale complete"
        subtitle={data ? `${data.order.order_no} is closed. Stock and the ledger are already updated.` : undefined}
        actions={
          <>
            <button className="btn primary" onClick={onNewSale} autoFocus>New sale</button>
            <button className="btn" onClick={() => window.print()}>Print receipt</button>
            <Link className="btn" to={`/sales/${id}`}>View order & accounting</Link>
          </>
        }
      />
      {change !== null && change > 0 && <div className="notice ok change-banner no-print">Change due: {money(change)}</div>}
      {loading && <Loading what="receipt" />}
      {error && <ErrorNotice message={error} />}
      {data && <Receipt view={data} companyName={companyName} returnDays={returnDays} />}
    </div>
  );
}
