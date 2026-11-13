import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, errorMessage, unwrap } from '../../lib/db';
import { date, money, unitCost } from '../../lib/format';
import type { Item, ItemSupplier, PurchaseOrder, Supplier } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { PoStatusBadge, RatingBadge, pct, termsOptions } from './purchasingShared';
import type { ScorecardRow } from './SuppliersPage';

type Form = Omit<Supplier, 'id'>;
const blank: Form = {
  name: '',
  contact_name: '',
  email: '',
  phone: '',
  website: '',
  address: '',
  quoted_lead_days: 7,
  payment_terms: 'Net 30',
  terms_days: 30,
  notes: '',
  is_active: true,
};

async function load(id: string | undefined) {
  if (!id) return null;
  const c = db();
  const supplier = await c.from('suppliers').select('*').eq('id', id).maybeSingle().then(unwrap<Supplier | null>);
  if (!supplier) throw new Error('That supplier does not exist.');
  const [score, prices, pos] = await Promise.all([
    c.from('v_supplier_scorecard').select('*').eq('supplier_id', id).maybeSingle().then(unwrap<ScorecardRow | null>),
    c.from('item_suppliers').select('*, item:items(id, name, sku, uom)').eq('supplier_id', id)
      .then((r) => unwrap(r) as unknown as (ItemSupplier & { item: Pick<Item, 'id' | 'name' | 'sku' | 'uom'> })[]),
    c.from('purchase_orders').select('*').eq('supplier_id', id).order('created_at', { ascending: false }).limit(50).then(unwrap<PurchaseOrder[]>),
  ]);
  return { supplier, score, prices, pos };
}

export function SupplierDetailPage() {
  const { id } = useParams();
  const isNew = !id;
  const navigate = useNavigate();
  const { data, error, loading } = useLiveQuery(() => load(id), ['suppliers', 'item_suppliers', 'purchase_orders', 'po_receipts', 'supplier_payments'], [id]);
  const [form, setForm] = useState<Form>(blank);
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  useEffect(() => {
    if (data?.supplier) {
      const { id: _id, ...rest } = data.supplier;
      void _id;
      setForm({ ...blank, ...rest });
    }
  }, [data?.supplier]);

  if (!isNew && loading) return <Loading what="supplier" />;
  if (error) return <ErrorNotice message={error} />;

  const set = <K extends keyof Form>(k: K, v: Form[K]) => setForm({ ...form, [k]: v });

  async function save() {
    setSaving(true);
    setMsg(null);
    try {
      const row = {
        ...form,
        name: form.name.trim(),
        contact_name: form.contact_name?.trim() || null,
        email: form.email?.trim() || null,
        phone: form.phone?.trim() || null,
        website: form.website?.trim() || null,
        address: form.address?.trim() || null,
        notes: form.notes?.trim() || null,
        quoted_lead_days: Math.max(0, Math.round(Number(form.quoted_lead_days))),
      };
      if (!row.name) throw new Error('Enter the supplier name.');
      if (isNew) {
        const created = await db().from('suppliers').insert(row).select('id').single().then(unwrap<{ id: string }>);
        navigate(`/suppliers/${created.id}`, { replace: true });
      } else {
        await db().from('suppliers').update(row).eq('id', id!).then((r) => unwrap(r));
        setMsg({ ok: true, text: 'Saved. New purchase orders use the new lead time and terms.' });
      }
    } catch (e) {
      setMsg({ ok: false, text: errorMessage(e) });
    } finally {
      setSaving(false);
    }
  }

  const s = data?.score;

  return (
    <div>
      <PageHeader
        title={isNew ? 'Add supplier' : form.name || 'Supplier'}
        subtitle={isNew ? 'Contact details, quoted lead time and payment terms.' : <>Scorecard computed from this supplier's purchase orders.</>}
        actions={
          <>
            {!isNew && <Link className="btn primary" to={`/purchasing/new?supplier=${id}`}>New PO</Link>}
            <Link className="btn" to="/suppliers">All suppliers</Link>
          </>
        }
      />

      {s && (
        <div className="stats">
          <Stat label="Overall rating" value={<>{s.overall_score ?? '—'} <RatingBadge rating={s.rating} /></>} hint={`${s.pos_delivered} delivered POs`} />
          <Stat label="On-time delivery" value={pct(s.on_time_rate)} hint={`${s.pos_on_time} of ${s.pos_delivered}`} />
          <Stat
            label="Lead time actual vs quoted"
            value={s.avg_actual_lead_days === null ? '—' : `${Number(s.avg_actual_lead_days).toFixed(1)} d`}
            hint={`Quoted ${s.quoted_lead_days} d · accuracy ${pct(s.lead_accuracy)}`}
          />
          <Stat label="Fill rate" value={pct(s.fill_rate, 1)} hint="Value received ÷ value ordered" />
          <Stat
            label="Owed"
            value={money(s.amount_owed)}
            hint={s.terms_days === 0 ? 'Paid at purchase' : s.next_due_date ? `Next due ${date(s.next_due_date)}` : 'Nothing due'}
            tone={Number(s.amount_overdue) > 0 ? 'bad' : undefined}
          />
        </div>
      )}

      <div className="detail-grid">
        <form
          className="form card"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <div className="form-row">
            <label className="grow">
              Name
              <input value={form.name} onChange={(e) => set('name', e.target.value)} required />
            </label>
            <label className="grow">
              Contact
              <input value={form.contact_name ?? ''} onChange={(e) => set('contact_name', e.target.value)} />
            </label>
          </div>
          <div className="form-row">
            <label className="grow">
              Email
              <input type="email" value={form.email ?? ''} onChange={(e) => set('email', e.target.value)} />
            </label>
            <label>
              Phone
              <input value={form.phone ?? ''} onChange={(e) => set('phone', e.target.value)} />
            </label>
          </div>
          <div className="form-row">
            <label className="grow">
              Website
              <input value={form.website ?? ''} onChange={(e) => set('website', e.target.value)} />
            </label>
            <label className="grow">
              Address
              <input value={form.address ?? ''} onChange={(e) => set('address', e.target.value)} />
            </label>
          </div>
          <div className="form-row">
            <label>
              Quoted lead time (days)
              <input type="number" min={0} step={1} value={form.quoted_lead_days} onChange={(e) => set('quoted_lead_days', Number(e.target.value))} />
            </label>
            <label>
              Payment terms
              <select
                value={form.terms_days}
                onChange={(e) => {
                  const t = termsOptions.find((o) => o.days === Number(e.target.value))!;
                  setForm({ ...form, terms_days: t.days, payment_terms: t.label });
                }}
              >
                {termsOptions.map((o) => (
                  <option key={o.days} value={o.days}>{o.label}</option>
                ))}
              </select>
            </label>
            <label className="check">
              <input type="checkbox" checked={form.is_active} onChange={(e) => set('is_active', e.target.checked)} />
              Active
            </label>
          </div>
          <label>
            Notes
            <textarea rows={2} value={form.notes ?? ''} onChange={(e) => set('notes', e.target.value)} />
          </label>
          {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'}`}>{msg.text}</div>}
          <div className="page-actions">
            <button className="btn primary" disabled={saving}>{saving ? 'Saving…' : isNew ? 'Add supplier' : 'Save changes'}</button>
          </div>
        </form>

        {!isNew && data && (
          <div>
            <h2 style={{ marginTop: 0 }}>Price list</h2>
            {data.prices.length === 0 ? (
              <p className="muted">No items yet.</p>
            ) : (
              <table className="table">
                <thead>
                  <tr>
                    <th>Item</th>
                    <th className="num">Price</th>
                    <th>Unit</th>
                  </tr>
                </thead>
                <tbody>
                  {data.prices.map((p) => (
                    <tr key={p.item_id}>
                      <td><Link to={`/inventory/item/${p.item_id}`}>{p.item.name}</Link>{p.is_preferred && <span className="badge ok">preferred</span>}</td>
                      <td className="num">{unitCost(p.unit_cost)}</td>
                      <td>{p.purchase_uom}{Number(p.stock_per_purchase_unit) !== 1 && <span className="muted small"> ({Number(p.stock_per_purchase_unit)} {p.item.uom})</span>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}
      </div>

      {!isNew && data && (
        <>
          <h2>Purchase order history</h2>
          {data.pos.length === 0 ? (
            <p className="muted">No purchase orders yet.</p>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>PO</th>
                    <th>Sent</th>
                    <th>Expected</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  {data.pos.map((p) => (
                    <tr key={p.id}>
                      <td><Link to={`/purchasing/${p.id}`}>{p.po_no}</Link></td>
                      <td>{date(p.order_date)}</td>
                      <td>{date(p.expected_date)}</td>
                      <td><PoStatusBadge status={p.status} /></td>
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
