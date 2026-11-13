import { useEffect, useMemo, useState } from 'react';
import { Link, NavLink, Navigate, Route, Routes, useNavigate, useSearchParams } from 'react-router-dom';
import { Logo } from '../../app/Logo';
import { LiveIndicator } from '../../app/LiveIndicator';
import { ErrorNotice, Loading } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import { date, dateTime, money } from '../../lib/format';
import { useAuth } from '../auth/AuthProvider';
import type { DiscountType } from '../../lib/types';
import { StatusBadge, TotalsTable, paymentLabels } from '../sales/salesShared';
import { TrackingCard } from '../tracking/TrackingCard';
import { trackingUrl } from '../tracking/tracking';
import {
  readCart,
  useCatalog,
  useMyOrders,
  usePortalQuote,
  writeCart,
  type Family,
  type PickupLocation,
  type PortalCartLine,
  type Variant,
} from './portalData';

// Customer portal (rubric capability 11): sign in, see what is available at
// each pickup location, place a pickup order, follow your orders.
// Everything a customer can do goes through portal_* database functions, which
// decide the customer, prices, discount and tax themselves.

export function CustomerHome() {
  const { session, fullName, signOut } = useAuth();
  const catalog = useCatalog();
  const initial = useMemo(readCart, []);
  const [lines, setLines] = useState<PortalCartLine[]>(initial.lines);
  const [locationId, setLocationId] = useState<string | null>(initial.locationId);

  const locations = catalog.data?.locations ?? [];
  const loc = locations.find((l) => l.id === locationId) ?? locations[0] ?? null;
  useEffect(() => writeCart(lines, loc?.id ?? null), [lines, loc?.id]);

  const units = lines.reduce((s, l) => s + l.qty, 0);
  const add = (itemId: string, n: number) =>
    setLines((ls) => (ls.some((l) => l.item_id === itemId) ? ls.map((l) => (l.item_id === itemId ? { ...l, qty: l.qty + n } : l)) : [...ls, { item_id: itemId, qty: n }]));

  const customer = catalog.data?.customer;
  return (
    <div className="portal">
      <header className="portal-top">
        <div className="brand">
          <Logo size={30} />
          <span>Poulson Prints</span>
        </div>
        <nav>
          <NavLink to="/" end>Shop</NavLink>
          <NavLink to="/cart">Cart{units > 0 ? ` (${units})` : ''}</NavLink>
          <NavLink to="/orders">My orders</NavLink>
        </nav>
        <div className="who">
          <LiveIndicator />
          <span>{customer?.name ?? fullName ?? session?.user.email}</span>
          <button className="btn" onClick={signOut}>Sign out</button>
        </div>
      </header>
      <main className="portal-main">
        {catalog.loading && <Loading what="products" />}
        {catalog.error && <ErrorNotice message={catalog.error} />}
        {catalog.data && !customer && (
          <div className="notice warn spaced">
            Your login is not linked to a customer account yet, so you can browse but not order. Please contact Poulson Prints
            (staff: the login's email must match the customer's email).
          </div>
        )}
        {catalog.data && (
          <Routes>
            <Route path="/" element={<Shop families={catalog.data.families} locations={locations} loc={loc} setLocationId={setLocationId} add={add} cartQty={(id) => lines.find((l) => l.item_id === id)?.qty ?? 0} />} />
            <Route
              path="/cart"
              element={<Cart lines={lines} setLines={setLines} variants={catalog.data.variants} locations={locations} loc={loc} setLocationId={setLocationId} canOrder={!!customer} />}
            />
            <Route path="/orders" element={<MyOrders />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        )}
      </main>
      {units > 0 && (
        <CartBar units={units} />
      )}
    </div>
  );
}

function CartBar({ units }: { units: number }) {
  const navigate = useNavigate();
  return (
    <div className="cart-bar portal-cartbar">
      <span>{units} item{units === 1 ? '' : 's'} in your cart</span>
      <button className="btn primary" onClick={() => navigate('/cart')}>Review &amp; place pickup order</button>
    </div>
  );
}

function LocationPicker({ locations, loc, setLocationId }: { locations: PickupLocation[]; loc: PickupLocation | null; setLocationId: (id: string) => void }) {
  return (
    <label style={{ maxWidth: 340 }}>
      Pick up at
      <select value={loc?.id ?? ''} onChange={(e) => setLocationId(e.target.value)}>
        {locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
      </select>
    </label>
  );
}

function availabilityText(v: Variant, locId: string | undefined): { text: string; tone: 'good' | 'muted' | 'bad' } {
  const r = locId ? v.at.get(locId) : undefined;
  if (!r) return { text: 'Not offered here', tone: 'muted' };
  const q = Number(r.qty_available);
  if (q > 0) return { text: `${q} available`, tone: 'good' };
  if (v.stocking_policy === 'make_to_order') return { text: `Made to order · ready about ${date(r.est_available_date)}`, tone: 'muted' };
  return { text: `Out of stock · expected ${date(r.est_available_date)}`, tone: 'bad' };
}

// ---------------------------------------------------------------------------
function Shop({
  families,
  locations,
  loc,
  setLocationId,
  add,
  cartQty,
}: {
  families: Family[];
  locations: PickupLocation[];
  loc: PickupLocation | null;
  setLocationId: (id: string) => void;
  add: (itemId: string, n: number) => void;
  cartQty: (itemId: string) => number;
}) {
  const [search, setSearch] = useState('');
  const [inStockOnly, setInStockOnly] = useState(false);
  const s = search.trim().toLowerCase();
  const shown = families.filter(
    (f) =>
      (!s || f.name.toLowerCase().includes(s) || f.variants.some((v) => v.name.toLowerCase().includes(s) || v.sku.toLowerCase().includes(s))) &&
      (!inStockOnly || f.variants.some((v) => Number(v.at.get(loc?.id ?? '')?.qty_available ?? 0) > 0)),
  );
  return (
    <>
      <h1>Shop 3D-printed gifts &amp; gear</h1>
      <p className="muted">
        Order online and pick up at the counter; pay when you pick up. Stock shown is live: what is on the shelf now, minus what other
        orders have reserved. Items that are not on the shelf can still be ordered and are printed for you.
      </p>
      <div className="toolbar">
        <LocationPicker locations={locations} loc={loc} setLocationId={setLocationId} />
        <label className="grow">
          Search
          <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Dragon, keychain, blue…" />
        </label>
        <label className="check" style={{ alignSelf: 'flex-end', paddingBottom: '0.6rem' }}>
          <input type="checkbox" checked={inStockOnly} onChange={(e) => setInStockOnly(e.target.checked)} /> In stock at this location only
        </label>
      </div>
      {shown.length === 0 && <p className="muted">No products match.</p>}
      <div className="product-grid">
        {shown.map((f) => <ProductCard key={f.key} family={f} locations={locations} loc={loc} add={add} cartQty={cartQty} />)}
      </div>
    </>
  );
}

function ProductCard({
  family,
  locations,
  loc,
  add,
  cartQty,
}: {
  family: Family;
  locations: PickupLocation[];
  loc: PickupLocation | null;
  add: (itemId: string, n: number) => void;
  cartQty: (itemId: string) => number;
}) {
  const [picked, setPicked] = useState(family.variants[0].item_id);
  const [n, setN] = useState('1');
  const v = family.variants.find((x) => x.item_id === picked) ?? family.variants[0];
  const a = availabilityText(v, loc?.id);
  const qtyOk = /^\d+$/.test(n.trim()) && Number(n) >= 1 && Number(n) <= 500;
  const inCart = cartQty(v.item_id);
  return (
    <div className="product-card">
      <h3>{family.name}</h3>
      <div className="price">{money(v.price)}</div>
      {family.variants.length > 1 && (
        <div className="swatches" role="group" aria-label="Color">
          {family.variants.map((x) => (
            <button key={x.item_id} type="button" className={`swatch ${x.item_id === v.item_id ? 'active' : ''}`} onClick={() => setPicked(x.item_id)}>
              {x.color ?? x.name}
            </button>
          ))}
        </div>
      )}
      <div className={`small strong ${a.tone}`}>{loc ? `${loc.name}: ` : ''}{a.text}</div>
      <ul className="stock-lines muted">
        {locations.filter((l) => l.id !== loc?.id).map((l) => (
          <li key={l.id}><span>{l.name}</span><span>{availabilityText(v, l.id).text}</span></li>
        ))}
      </ul>
      <div className="inline-form">
        <input className="qty-input" type="number" min="1" max="500" step="1" value={n} onChange={(e) => setN(e.target.value)} aria-label={`Quantity of ${v.name}`} />
        <button type="button" className="btn primary" disabled={!qtyOk} onClick={() => { add(v.item_id, Number(n)); setN('1'); }}>
          Add to cart
        </button>
      </div>
      {!qtyOk && <div className="field-error">Enter a whole number from 1 to 500.</div>}
      {inCart > 0 && <div className="small muted">{inCart} in your cart</div>}
    </div>
  );
}

// ---------------------------------------------------------------------------
function Cart({
  lines,
  setLines,
  variants,
  locations,
  loc,
  setLocationId,
  canOrder,
}: {
  lines: PortalCartLine[];
  setLines: (f: (ls: PortalCartLine[]) => PortalCartLine[]) => void;
  variants: Map<string, Variant>;
  locations: PickupLocation[];
  loc: PickupLocation | null;
  setLocationId: (id: string) => void;
  canOrder: boolean;
}) {
  const navigate = useNavigate();
  const [needDate, setNeedDate] = useState('');
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [placeError, setPlaceError] = useState<string | null>(null);
  // Items no longer sold (e.g. out of season) drop out of the cart.
  const valid = lines.filter((l) => variants.has(l.item_id));
  const payload =
    canOrder && loc && valid.length > 0
      ? { location_id: loc.id, lines: valid.map((l) => ({ item_id: l.item_id, qty: l.qty })), need_date: needDate || null, notes: notes || null }
      : null;
  const { quote, error, pricing } = usePortalQuote(payload);

  async function place() {
    if (!payload) return;
    setBusy(true);
    setPlaceError(null);
    try {
      const id = await rpc<string>('portal_place_order', { p: payload });
      setLines(() => []);
      navigate(`/orders?placed=${id}`);
    } catch (e) {
      setPlaceError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  if (valid.length === 0) {
    return (
      <>
        <h1>Your cart</h1>
        <p className="muted">Your cart is empty. <Link to="/">Browse products</Link></p>
      </>
    );
  }
  const latest = valid.reduce<string | null>((m, l) => {
    const r = loc ? variants.get(l.item_id)?.at.get(loc.id) : undefined;
    const d = r && l.qty > Number(r.qty_available) ? r.est_available_date : null;
    return d && (!m || d > m) ? d : m;
  }, null);
  return (
    <>
      <h1>Your cart</h1>
      <div className="pos-grid">
        <div className="form">
          <LocationPicker locations={locations} loc={loc} setLocationId={setLocationId} />
          <div className="table-wrap">
            <table className="table cart">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="num">Price</th>
                  <th className="num">Qty</th>
                  <th className="num">Line total</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {valid.map((l) => {
                  const v = variants.get(l.item_id)!;
                  const r = loc ? v.at.get(loc.id) : undefined;
                  const avail = Number(r?.qty_available ?? 0);
                  const short = l.qty > avail;
                  return (
                    <tr key={l.item_id}>
                      <td>
                        {v.name}
                        <div className={`small ${short ? 'bad' : 'muted'}`}>
                          {short
                            ? `${avail > 0 ? `${avail} on the shelf; the rest` : v.stocking_policy === 'make_to_order' ? 'Printed for you,' : 'Restocking,'} ready about ${date(r?.est_available_date)}`
                            : `${avail} available here`}
                        </div>
                      </td>
                      <td className="num">{money(v.price)}</td>
                      <td className="num">
                        <div className="qty-stepper">
                          <button type="button" className="btn" aria-label={`One fewer ${v.name}`} onClick={() => setLines((ls) => ls.map((x) => (x.item_id === l.item_id ? { ...x, qty: Math.max(1, x.qty - 1) } : x)))}>−</button>
                          <input
                            className="qty-input"
                            type="number"
                            min="1"
                            max="500"
                            step="1"
                            value={l.qty}
                            aria-label={`Quantity of ${v.name}`}
                            onChange={(e) => {
                              const q = Math.floor(Number(e.target.value));
                              if (q >= 1) setLines((ls) => ls.map((x) => (x.item_id === l.item_id ? { ...x, qty: Math.min(q, 500) } : x)));
                            }}
                          />
                          <button type="button" className="btn" aria-label={`One more ${v.name}`} onClick={() => setLines((ls) => ls.map((x) => (x.item_id === l.item_id ? { ...x, qty: Math.min(500, x.qty + 1) } : x)))}>+</button>
                        </div>
                      </td>
                      <td className="num">{money(quote?.lines.find((x) => x.item_id === l.item_id)?.line_total ?? l.qty * v.price)}</td>
                      <td>
                        <button type="button" className="btn link" onClick={() => setLines((ls) => ls.filter((x) => x.item_id !== l.item_id))}>Remove</button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <div className="form-row">
            <label>
              Need it by (optional)
              <input type="date" value={needDate} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setNeedDate(e.target.value)} />
            </label>
            <label className="grow">
              Note for the shop (optional)
              <input value={notes} maxLength={500} onChange={(e) => setNotes(e.target.value)} placeholder="Gift wrap, pickup time…" />
            </label>
          </div>
        </div>
        <div className="card pos-pay action-card">
          <h2 style={{ marginTop: 0 }}>Pickup order</h2>
          {error && <div className="notice error">{error}</div>}
          {!quote && !error && <p className="muted">{pricing ? 'Pricing…' : canOrder ? '' : 'Ordering needs a linked customer account.'}</p>}
          {quote && (
            <div className={pricing ? 'repricing' : ''}>
              <TotalsTable t={quote} />
              <p className="muted small">
                Pay {quote.payment_method === 'account' ? 'on your account (invoice terms)' : 'at the counter when you pick up'}.
                {quote.discount_type === 'byu' && ' Your BYU student discount is applied.'}
                {quote.discount_type === 'business' && ' Your business bulk discount is applied.'}
              </p>
            </div>
          )}
          <p className="small">
            Pick up at <strong>{loc?.name}</strong>
            {latest ? <>, ready about <strong>{date(latest)}</strong> (we will have everything then).</> : ', ready now: everything is on the shelf.'}
          </p>
          {placeError && <div className="notice error">{placeError}</div>}
          <button className="btn primary big" disabled={!quote || pricing || busy || !!error} onClick={place}>
            {busy ? 'Placing…' : `Place pickup order${quote ? ` · ${money(quote.total)}` : ''}`}
          </button>
        </div>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
function customerStatus(status: string, backordered: boolean, latest: string | null, where: string): string {
  if (status === 'placed') return backordered ? `Being made / restocked: ready for pickup about ${date(latest)} at ${where}.` : `Ready for pickup at ${where}. We are holding it for you.`;
  if (status === 'fulfilled') return 'Picked up.';
  if (status === 'closed') return 'Complete. Thank you!';
  return 'Cancelled.';
}

function MyOrders() {
  const { data, error, loading } = useMyOrders();
  const [params] = useSearchParams();
  const placed = params.get('placed');
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  async function cancel(id: string, no: string) {
    if (!window.confirm(`Cancel order ${no}?`)) return;
    setBusy(id);
    setActionError(null);
    try {
      await rpc('portal_cancel_order', { p_so_id: id });
    } catch (e) {
      setActionError(errorMessage(e));
    } finally {
      setBusy(null);
    }
  }

  const justPlaced = data?.orders.find((o) => o.id === placed);
  return (
    <>
      <h1>My orders</h1>
      {justPlaced && (
        <div className="notice ok spaced">
          Thank you! Order <strong>{justPlaced.order_no}</strong> is placed ({money(justPlaced.total)}). Show this order number at the counter.
        </div>
      )}
      {justPlaced && (
        <TrackingCard soId={justPlaced.id} token={justPlaced.tracking_token} orderNo={justPlaced.order_no} defaultEmail={justPlaced.customer_email} showLog={false} compact />
      )}
      {actionError && <ErrorNotice message={actionError} />}
      {loading && <Loading what="your orders" />}
      {error && <ErrorNotice message={error} />}
      {data && data.orders.length === 0 && <p className="muted">No orders yet. <Link to="/">Start shopping</Link></p>}
      {data &&
        data.orders.map((o) => {
          const bo = data.backorders.filter((b) => b.so_id === o.id);
          const latest = bo.reduce<string | null>((m, b) => (b.est_available_date && (!m || b.est_available_date > m) ? b.est_available_date : m), null);
          const where = data.locationName.get(o.location_id) ?? '';
          return (
            <div key={o.id} className={`card spaced ${o.id === placed ? 'highlight' : ''}`}>
              <div className="page-header" style={{ marginBottom: '0.5rem' }}>
                <div>
                  <h2 style={{ margin: 0 }}>{o.order_no} <StatusBadge status={o.status} backordered={o.status === 'placed' && bo.length > 0} /></h2>
                  <p className="muted small">
                    {dateTime(o.order_date)} · {o.fulfillment_method === 'pickup' ? `Pickup at ${where}` : o.fulfillment_method === 'ship' ? 'Shipped' : 'Counter sale'}
                    {o.payment_method && ` · ${paymentLabels[o.payment_method] ?? o.payment_method}`}
                  </p>
                </div>
                <div className="page-actions">
                {o.tracking_token && <a className="btn" href={trackingUrl(o.tracking_token)} target="_blank" rel="noreferrer">Track</a>}
                {o.status === 'placed' && (
                  <button className="btn" disabled={busy === o.id} onClick={() => cancel(o.id, o.order_no)}>{busy === o.id ? 'Cancelling…' : 'Cancel order'}</button>
                )}
                </div>
              </div>
              <p className="small" style={{ margin: '0 0 0.5rem' }}>{customerStatus(o.status, bo.length > 0, latest, where)}</p>
              <div className="detail-grid">
                <table className="table">
                  <tbody>
                    {[...o.sales_order_lines].sort((a, b) => a.line_no - b.line_no).map((l) => {
                      const b = bo.find((x) => x.so_line_id === l.id);
                      return (
                        <tr key={l.id}>
                          <td>
                            {data.itemName.get(l.item_id) ?? 'Item'}
                            {b && <div className="small bad">{Number(b.qty_backordered)} waiting · about {date(b.est_available_date)}</div>}
                            {Number(l.qty_returned) > 0 && <div className="small muted">{Number(l.qty_returned)} returned</div>}
                          </td>
                          <td className="num">× {Number(l.qty)}</td>
                          <td className="num">{money(l.line_total)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
                <TotalsTable t={{ ...o, discount_type: o.discount_type as DiscountType }} />
              </div>
            </div>
          );
        })}
    </>
  );
}
