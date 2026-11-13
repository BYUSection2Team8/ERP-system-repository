import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { date, money } from '../../lib/format';
import type { ApOpen, PoStatus, PurchaseOrder, PurchaseOrderLine, Supplier } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { localToday } from '../production/productionShared';
import { PoStatusBadge, poSourceLabels } from './purchasingShared';

type Tab = 'open' | 'received' | 'closed' | 'draft' | 'cancelled' | 'all';
const tabs: { key: Tab; label: string; statuses: PoStatus[] | null }[] = [
  { key: 'open', label: 'Open (sent)', statuses: ['sent', 'partial'] },
  { key: 'received', label: 'Received', statuses: ['received'] },
  { key: 'closed', label: 'Closed', statuses: ['closed'] },
  { key: 'draft', label: 'Drafts', statuses: ['draft'] },
  { key: 'cancelled', label: 'Cancelled', statuses: ['cancelled'] },
  { key: 'all', label: 'All', statuses: null },
];
const LIMIT = 200;

async function load(tab: Tab) {
  const c = db();
  const statuses = tabs.find((t) => t.key === tab)!.statuses;
  let q = c.from('purchase_orders').select('*');
  if (statuses) q = q.in('status', statuses);
  const [pos, suppliers, openLines, ap, counts] = await Promise.all([
    q.order('created_at', { ascending: false }).limit(LIMIT).then(unwrap<PurchaseOrder[]>),
    c.from('suppliers').select('*').then(unwrap<Supplier[]>),
    c.from('purchase_order_lines').select('po_id, qty_ordered, qty_received, unit_cost, po:purchase_orders!inner(status)')
      .in('po.status', ['sent', 'partial'])
      .then((r) => unwrap(r) as unknown as (Pick<PurchaseOrderLine, 'po_id' | 'qty_ordered' | 'qty_received' | 'unit_cost'>)[]),
    c.from('v_ap_open').select('*').gt('balance', 0).order('due_date').then(unwrap<ApOpen[]>),
    Promise.all(
      tabs.filter((t) => t.statuses).map((t) =>
        c.from('purchase_orders').select('id', { count: 'exact', head: true }).in('status', t.statuses!).then((r) => {
          if (r.error) throw new Error(r.error.message);
          return [t.key, r.count ?? 0] as const;
        }),
      ),
    ),
  ]);
  const value = new Map<string, number>();
  for (const l of openLines) value.set(l.po_id, (value.get(l.po_id) ?? 0) + (Number(l.qty_ordered) - Number(l.qty_received)) * Number(l.unit_cost));
  return {
    pos,
    suppliers: new Map(suppliers.map((s) => [s.id, s])),
    openValue: value,
    ap,
    counts: new Map<Tab, number>(counts),
  };
}

export function PurchaseOrdersPage() {
  const [tab, setTab] = useState<Tab>('open');
  const [search, setSearch] = useState('');
  const navigate = useNavigate();
  const { data, error, loading } = useLiveQuery(() => load(tab), ['purchase_orders', 'purchase_order_lines', 'po_receipts', 'supplier_payments'], [tab]);
  const [paying, setPaying] = useState<string | null>(null);
  const [payResult, setPayResult] = useState<{ ok: boolean; text: string } | null>(null);
  const today = localToday();

  const rows = useMemo(() => {
    if (!data) return [];
    const t = search.trim().toLowerCase();
    if (!t) return data.pos;
    return data.pos.filter((p) => p.po_no.toLowerCase().includes(t) || (data.suppliers.get(p.supplier_id)?.name ?? '').toLowerCase().includes(t));
  }, [data, search]);

  async function pay(bill: ApOpen) {
    setPaying(bill.receipt_id);
    setPayResult(null);
    try {
      await rpc('record_supplier_payment', { p_receipt_id: bill.receipt_id, p_amount: null, p_method: 'ACH' });
      setPayResult({ ok: true, text: `Paid ${money(bill.balance)} to ${bill.supplier_name} for ${bill.po_no} (Accounts payable down, Cash down).` });
    } catch (e) {
      setPayResult({ ok: false, text: errorMessage(e) });
    } finally {
      setPaying(null);
    }
  }

  const owed = data?.ap.reduce((s, b) => s + Number(b.balance), 0) ?? 0;
  const overdue = data?.ap.filter((b) => b.is_overdue) ?? [];
  const onOrder = data ? [...data.openValue.values()].reduce((s, v) => s + v, 0) : 0;

  return (
    <div>
      <PageHeader
        title="Purchase orders"
        subtitle="Order sent → Received (partial receipts allowed, into any location) → Closed. The expected date is the sent date + the supplier's quoted lead time."
        actions={
          <>
            <Link className="btn primary" to="/purchasing/new">New purchase order</Link>
            <Link className="btn" to="/purchasing/planning">Reorder planning</Link>
            <Link className="btn" to="/suppliers">Suppliers</Link>
          </>
        }
      />
      {loading && <Loading what="purchase orders" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Open purchase orders" value={data.counts.get('open') ?? 0} hint={`${money(onOrder)} still to arrive`} />
            <Stat label="Owed to suppliers" value={money(owed)} hint={`${data.ap.length} open bill${data.ap.length === 1 ? '' : 's'}`} />
            <Stat
              label="Overdue bills"
              value={money(overdue.reduce((s, b) => s + Number(b.balance), 0))}
              hint={`${overdue.length} past due date`}
              tone={overdue.length ? 'bad' : undefined}
            />
            <Stat label="Received, not closed" value={data.counts.get('received') ?? 0} />
          </div>

          <div className="toolbar">
            <div className="tabs">
              {tabs.map((t) => (
                <button key={t.key} className={tab === t.key ? 'active' : ''} onClick={() => setTab(t.key)}>
                  {t.label}
                  {t.statuses && <span className="tab-count">{data.counts.get(t.key) ?? 0}</span>}
                </button>
              ))}
            </div>
            <input className="grow" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search PO number or supplier" aria-label="Search purchase orders" />
          </div>

          {rows.length === 0 ? (
            <div className="card muted">No purchase orders here.</div>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>PO</th>
                    <th>Supplier</th>
                    <th>Sent</th>
                    <th>Expected</th>
                    <th>Source</th>
                    <th>Status</th>
                    <th className="num">Open value</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((p) => {
                    const late = (p.status === 'sent' || p.status === 'partial') && p.expected_date !== null && p.expected_date < today;
                    return (
                      <tr key={p.id} className="clickable" onClick={() => navigate(`/purchasing/${p.id}`)}>
                        <td className="strong"><Link to={`/purchasing/${p.id}`} onClick={(e) => e.stopPropagation()}>{p.po_no}</Link></td>
                        <td>{data.suppliers.get(p.supplier_id)?.name}</td>
                        <td>{date(p.order_date)}</td>
                        <td className={late ? 'bad strong' : ''}>{date(p.expected_date)}{late && <div className="small">overdue</div>}</td>
                        <td>{poSourceLabels[p.source] ?? p.source}</td>
                        <td><PoStatusBadge status={p.status} /></td>
                        <td className="num">{data.openValue.has(p.id) ? money(data.openValue.get(p.id)) : '—'}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
          {data.pos.length === LIMIT && <p className="muted small">Showing the latest {LIMIT}.</p>}

          <h2>Bills to pay (accounts payable)</h2>
          <p className="muted small">Each receipt from a Net-terms supplier is a bill due on the received date + the supplier's terms. Paid-at-purchase suppliers are settled on receipt.</p>
          {payResult && <div className={`notice ${payResult.ok ? 'ok' : 'error'} spaced`}>{payResult.text}</div>}
          {data.ap.length === 0 ? (
            <p className="muted">Nothing owed.</p>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Supplier</th>
                    <th>PO</th>
                    <th>Received</th>
                    <th>Due</th>
                    <th className="num">Bill</th>
                    <th className="num">Paid</th>
                    <th className="num">Balance</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {data.ap.map((b) => (
                    <tr key={b.receipt_id}>
                      <td><Link to={`/suppliers/${b.supplier_id}`}>{b.supplier_name}</Link></td>
                      <td><Link to={`/purchasing/${b.po_id}`}>{b.po_no}</Link></td>
                      <td>{date(b.received_at)}</td>
                      <td className={b.is_overdue ? 'bad strong' : ''}>{date(b.due_date)}{b.is_overdue && <div className="small">overdue</div>}</td>
                      <td className="num">{money(b.amount)}</td>
                      <td className="num">{money(b.amount_paid)}</td>
                      <td className="num strong">{money(b.balance)}</td>
                      <td>
                        <button className="btn" disabled={paying !== null} onClick={() => pay(b)}>
                          {paying === b.receipt_id ? 'Paying…' : 'Pay'}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
