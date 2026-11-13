import { Link, useNavigate } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { date, money } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { RatingBadge, ScoreBar, pct } from './purchasingShared';

export interface ScorecardRow {
  supplier_id: string;
  name: string;
  contact_name: string | null;
  email: string | null;
  phone: string | null;
  quoted_lead_days: number;
  payment_terms: string;
  terms_days: number;
  is_active: boolean;
  pos_delivered: number;
  pos_on_time: number;
  on_time_rate: number | null;
  avg_actual_lead_days: number | null;
  avg_quoted_lead_days: number | null;
  avg_days_late: number | null;
  lead_accuracy: number | null;
  fill_rate: number | null;
  price_cv: number | null;
  price_stability: number | null;
  receipts: number;
  open_pos: number;
  open_po_value: number;
  amount_owed: number;
  amount_overdue: number;
  next_due_date: string | null;
  open_bills: number;
  total_billed: number;
  payments: number;
  paid_on_time_rate: number | null;
  overall_score: number | null;
  rating: string;
}

async function load() {
  return db().from('v_supplier_scorecard').select('*').order('name').then(unwrap<ScorecardRow[]>);
}

export function SuppliersPage() {
  const { data, error, loading } = useLiveQuery(load, ['suppliers', 'purchase_orders', 'po_receipts', 'supplier_payments']);
  const navigate = useNavigate();

  const counts = { Keep: 0, Watch: 0, Replace: 0 } as Record<string, number>;
  for (const s of data ?? []) counts[s.rating] = (counts[s.rating] ?? 0) + 1;
  const owed = (data ?? []).reduce((s, r) => s + Number(r.amount_owed), 0);

  return (
    <div>
      <PageHeader
        title="Suppliers and scorecard"
        subtitle="Every measure is computed from purchase-order history (receipts vs expected dates, quantities received vs ordered, prices paid, bills and payments). The history itself was simulated through the real PO functions."
        actions={<Link className="btn primary" to="/suppliers/new">Add supplier</Link>}
      />
      {loading && <Loading what="suppliers" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Keep (80+)" value={counts.Keep ?? 0} />
            <Stat label="Watch (60–79)" value={counts.Watch ?? 0} tone={counts.Watch ? 'warn' : undefined} />
            <Stat label="Replace (below 60)" value={counts.Replace ?? 0} tone={counts.Replace ? 'bad' : undefined} />
            <Stat label="Owed to suppliers" value={money(owed)} hint={<Link to="/purchasing">Bills to pay</Link>} />
          </div>

          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Supplier</th>
                  <th className="num">POs delivered</th>
                  <th className="num">On time <span className="muted small">40%</span></th>
                  <th className="num">Fill rate <span className="muted small">30%</span></th>
                  <th className="num">Lead time actual vs quoted <span className="muted small">accuracy 20%</span></th>
                  <th className="num">Price stability <span className="muted small">10%</span></th>
                  <th className="num">Owed</th>
                  <th>Next due</th>
                  <th className="num">Paid on time</th>
                  <th className="num">Overall</th>
                  <th>Rating</th>
                </tr>
              </thead>
              <tbody>
                {data.map((s) => (
                  <tr key={s.supplier_id} className="clickable" onClick={() => navigate(`/suppliers/${s.supplier_id}`)}>
                    <td>
                      <Link to={`/suppliers/${s.supplier_id}`} onClick={(e) => e.stopPropagation()} className="strong">{s.name}</Link>
                      <div className="muted small">{s.payment_terms} · quoted {s.quoted_lead_days} d{!s.is_active && ' · inactive'}</div>
                    </td>
                    <td className="num">{s.pos_delivered}{s.open_pos > 0 && <div className="muted small">{s.open_pos} open</div>}</td>
                    <td className="num">{pct(s.on_time_rate)}<ScoreBar value={s.on_time_rate} /><div className="muted small">{s.pos_on_time}/{s.pos_delivered}</div></td>
                    <td className="num">{pct(s.fill_rate, 1)}<ScoreBar value={s.fill_rate} /></td>
                    <td className="num">
                      {s.avg_actual_lead_days === null ? '—' : `${Number(s.avg_actual_lead_days).toFixed(1)} vs ${Number(s.avg_quoted_lead_days).toFixed(0)} d`}
                      <ScoreBar value={s.lead_accuracy} />
                      <div className="muted small">{s.avg_days_late !== null && Number(s.avg_days_late) > 0 ? `avg ${Number(s.avg_days_late).toFixed(1)} d late` : ''}</div>
                    </td>
                    <td className="num">{pct(s.price_stability)}<ScoreBar value={s.price_stability} /></td>
                    <td className={`num ${Number(s.amount_overdue) > 0 ? 'bad' : ''}`}>
                      {money(s.amount_owed)}
                      {Number(s.amount_overdue) > 0 && <div className="small">{money(s.amount_overdue)} overdue</div>}
                    </td>
                    <td>{s.terms_days === 0 ? <span className="muted">paid at purchase</span> : date(s.next_due_date)}</td>
                    <td className="num">{pct(s.paid_on_time_rate)}</td>
                    <td className="num strong">{s.overall_score ?? '—'}</td>
                    <td><RatingBadge rating={s.rating} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="card muted small spaced">
            <strong>How the rating works.</strong> Overall = 40% on-time delivery (last receipt on or before the expected date) + 30% fill rate (value received ÷
            value ordered on finished POs, so short shipments count) + 20% lead-time accuracy (1 − average |actual − quoted| ÷ quoted) + 10% price stability
            (1 − 2 × the variation in prices paid per item). Keep at 80 or more, Watch 60–79, Replace below 60. Amounts owed and due dates come from
            receipts and the supplier's payment terms.
          </div>
        </>
      )}
    </div>
  );
}
