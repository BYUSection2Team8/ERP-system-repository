import { useEffect, useRef, useState } from 'react';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import type { Customer, Quote, SoStatus } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';

// Data for the customer portal. Customers cannot read stock movements, so
// availability comes from the portal_catalog() database function, and screens
// refresh through the live_signals table (bumped on every stock / order change).

export interface CatalogRow {
  item_id: string;
  sku: string;
  barcode: string;
  name: string;
  description: string | null;
  product_family: string | null;
  color: string | null;
  price: number;
  stocking_policy: 'stock' | 'make_to_order' | 'seasonal';
  lead_time_days: number | null;
  location_id: string;
  location_code: string;
  location_name: string;
  qty_available: number;
  est_available_date: string | null;
}

export interface Variant {
  item_id: string;
  name: string;
  sku: string;
  color: string | null;
  price: number;
  stocking_policy: CatalogRow['stocking_policy'];
  /** location_id -> row */
  at: Map<string, CatalogRow>;
}

export interface Family {
  key: string;
  name: string;
  variants: Variant[];
}

export interface PickupLocation {
  id: string;
  code: string;
  name: string;
}

async function loadCatalog() {
  const c = db();
  const [rows, customer] = await Promise.all([
    c.rpc('portal_catalog').then(unwrap<CatalogRow[]>),
    c.from('customers').select('*').maybeSingle().then(unwrap<Customer | null>),
  ]);
  const families = new Map<string, Family>();
  const variants = new Map<string, Variant>();
  const locations = new Map<string, PickupLocation>();
  for (const r of rows) {
    locations.set(r.location_id, { id: r.location_id, code: r.location_code, name: r.location_name });
    let v = variants.get(r.item_id);
    if (!v) {
      v = { item_id: r.item_id, name: r.name, sku: r.sku, color: r.color, price: Number(r.price), stocking_policy: r.stocking_policy, at: new Map() };
      variants.set(r.item_id, v);
      const key = r.product_family ?? r.name;
      let f = families.get(key);
      if (!f) {
        f = { key, name: key, variants: [] };
        families.set(key, f);
      }
      f.variants.push(v);
    }
    v.at.set(r.location_id, r);
  }
  // Campus counter first: that is the usual pickup spot.
  const locs = [...locations.values()].sort((a, b) => (a.code === 'CAMPUS' ? -1 : b.code === 'CAMPUS' ? 1 : a.name.localeCompare(b.name)));
  return { families: [...families.values()], variants, locations: locs, customer };
}

export function useCatalog() {
  return useLiveQuery(loadCatalog, ['live_signals', 'items', 'settings', 'customers']);
}

export interface PortalOrder {
  id: string;
  order_no: string;
  order_date: string;
  status: SoStatus;
  channel: string;
  fulfillment_method: string;
  location_id: string;
  subtotal: number;
  discount_type: string;
  discount_pct: number;
  discount_amount: number;
  tax_rate: number;
  ship_state: string | null;
  shipping_amount: number;
  tax_amount: number;
  total: number;
  payment_method: string | null;
  need_date: string | null;
  fulfilled_at: string | null;
  closed_at: string | null;
  cancelled_at: string | null;
  notes: string | null;
  tracking_token: string | null;
  customer_email: string | null;
  sales_order_lines: { id: string; line_no: number; item_id: string; qty: number; unit_price: number; net_unit_price: number; line_total: number; qty_returned: number }[];
}

export interface PortalBackorder {
  so_id: string;
  so_line_id: string;
  item_id: string;
  qty_backordered: number;
  est_available_date: string | null;
}

async function loadOrders() {
  const c = db();
  const [orders, backorders, items, locations] = await Promise.all([
    c.from('sales_orders').select('*, sales_order_lines(*)').order('order_date', { ascending: false }).limit(100).then(unwrap<PortalOrder[]>),
    c.rpc('portal_order_backorders').then(unwrap<PortalBackorder[]>),
    c.from('items').select('id, name, sku').then(unwrap<{ id: string; name: string; sku: string }[]>),
    c.from('locations').select('id, name').then(unwrap<{ id: string; name: string }[]>),
  ]);
  return {
    orders,
    backorders,
    itemName: new Map(items.map((i) => [i.id, i.name])),
    locationName: new Map(locations.map((l) => [l.id, l.name])),
  };
}

export function useMyOrders() {
  return useLiveQuery(loadOrders, ['sales_orders', 'sales_order_lines', 'live_signals']);
}

/** Price the cart in the database (same function that will save the order). */
export function usePortalQuote(payload: Record<string, unknown> | null) {
  const [quote, setQuote] = useState<Quote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pricing, setPricing] = useState(false);
  const seq = useRef(0);
  const key = payload ? JSON.stringify(payload) : '';

  useEffect(() => {
    const mine = ++seq.current;
    if (!key) {
      setQuote(null);
      setError(null);
      setPricing(false);
      return;
    }
    setPricing(true);
    const t = window.setTimeout(async () => {
      try {
        const q = await rpc<Quote>('portal_quote_order', { p: JSON.parse(key) });
        if (mine !== seq.current) return;
        setQuote(q);
        setError(null);
      } catch (e) {
        if (mine !== seq.current) return;
        setQuote(null);
        setError(errorMessage(e));
      } finally {
        if (mine === seq.current) setPricing(false);
      }
    }, 250);
    return () => window.clearTimeout(t);
  }, [key]);

  return { quote, error, pricing };
}

// ---------------------------------------------------------------------------
// Cart: kept in this browser only (a convenience), cleared after ordering.
// ---------------------------------------------------------------------------
export interface PortalCartLine {
  item_id: string;
  qty: number;
}

const CART_KEY = 'pp-portal-cart';

export function readCart(): { lines: PortalCartLine[]; locationId: string | null } {
  try {
    const v = JSON.parse(localStorage.getItem(CART_KEY) ?? 'null');
    if (v && Array.isArray(v.lines)) return { lines: v.lines.filter((l: PortalCartLine) => l && typeof l.item_id === 'string' && l.qty > 0), locationId: v.locationId ?? null };
  } catch {
    /* storage unavailable: start empty */
  }
  return { lines: [], locationId: null };
}

export function writeCart(lines: PortalCartLine[], locationId: string | null) {
  try {
    localStorage.setItem(CART_KEY, JSON.stringify({ lines, locationId }));
  } catch {
    /* storage unavailable: cart lives for this page only */
  }
}
