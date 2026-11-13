import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { date, dateTime, money, qty, unitCost } from '../../lib/format';
import type { Account, Availability, Item, LedgerRow, Location, ProductionOrder, ProductionOrderComponent, ReasonCode } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { JournalTables } from '../../app/JournalTables';
import { MoStatusBadge, hoursText, nowLocalInput, useProductionRefData } from './productionShared';

interface ComponentView extends ProductionOrderComponent {
  item: Pick<Item, 'id' | 'sku' | 'name' | 'uom'>;
}

interface View {
  mo: ProductionOrder;
  item: Item;
  components: ComponentView[];
  build: Location;
  output: Location;
  ledger: LedgerRow[];
  accounts: Map<string, Account>;
  so: { id: string; order_no: string } | null;
  stock: Map<string, number>;
}

async function load(id: string): Promise<View> {
  const c = db();
  const mo = await c.from('production_orders').select('*').eq('id', id).maybeSingle().then(unwrap<ProductionOrder | null>);
  if (!mo) throw new Error('That production order does not exist.');
  const [item, components, locations, ledger, accounts, so, avail] = await Promise.all([
    c.from('items').select('*').eq('id', mo.item_id).single().then(unwrap<Item>),
    c.from('production_order_components')
      .select('*, item:items(id, sku, name, uom)')
      .eq('mo_id', id)
      .then((r) => unwrap(r) as unknown as ComponentView[]),
    c.from('locations').select('*').in('id', [mo.location_id, mo.output_location_id]).then(unwrap<Location[]>),
    c.from('ledger').select('id, journal_id, posted_at, account_code, debit, credit, source_type, memo').eq('source_id', id).order('posted_at').order('id').then(unwrap<LedgerRow[]>),
    c.from('accounts').select('code, name, type').then(unwrap<Account[]>),
    mo.so_id ? c.from('sales_orders').select('id, order_no').eq('id', mo.so_id).maybeSingle().then(unwrap<{ id: string; order_no: string } | null>) : Promise.resolve(null),
    c.from('v_availability').select('*').eq('location_id', mo.location_id).then(unwrap<Availability[]>),
  ]);
  const loc = (lid: string) => locations.find((l) => l.id === lid)!;
  return {
    mo,
    item,
    components: components.sort((a, b) => a.item.name.localeCompare(b.item.name)),
    build: loc(mo.location_id),
    output: loc(mo.output_location_id),
    ledger,
    accounts: new Map(accounts.map((a) => [a.code, a])),
    so,
    stock: new Map(avail.map((a) => [a.item_id, Number(a.qty_on_hand)])),
  };
}

export function ProductionOrderDetailPage() {
  const { id = '' } = useParams();
  const { data, error, loading } = useLiveQuery(() => load(id), ['production_orders', 'production_order_components', 'inventory_txn', 'ledger'], [id]);
  const ref = useProductionRefData();
  const [busy, setBusy] = useState<string | null>(null);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);
  const [startAt, setStartAt] = useState(nowLocalInput());
  const [good, setGood] = useState('');
  const [scrapReason, setScrapReason] = useState('');
  const [finishAt, setFinishAt] = useState(nowLocalInput());
  const [cancelling, setCancelling] = useState(false);
  const [cancelReason, setCancelReason] = useState('');

  if (loading) return <Loading what="production order" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const { mo, item, components } = data;

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

  const short = components.filter((c) => (data.stock.get(c.item_id) ?? 0) < Number(c.qty_required));
  const started = Number(mo.qty_started);
  const goodN = good === '' ? started : Number(good);
  const scrapN = started - goodN;
  const goodValid = Number.isInteger(goodN) && goodN >= 0 && goodN <= started;
  const needReason = scrapN > 0;

  // Cost-rate explanation (same settings the database used / will use).
  const s = ref.data?.settings;
  const laborRate = s?.get('labor_rate') ?? 0;
  const perPlateMin = (s?.get('setup_minutes_per_plate') ?? 0) + (s?.get('cleanup_minutes_per_plate') ?? 0) + Number(item.assembly_minutes ?? 0);
  const printHours = Number(item.print_minutes ?? 0) / 60;
  const std = ref.data?.standardCost.get(item.id);

  return (
    <div>
      <PageHeader
        title={`Production order ${mo.mo_no}`}
        subtitle={
          <>
            {qty(mo.qty_planned)} × <Link to={`/inventory/item/${item.id}`}>{item.name}</Link> · {mo.plates} plate{mo.plates === 1 ? '' : 's'} of {item.units_per_plate} · build at {data.build.name}
          </>
        }
        actions={<Link className="btn" to="/production">All production orders</Link>}
      />

      <Steps mo={mo} />

      {mo.status === 'planned' && (
        <div className="card action-card">
          {short.length > 0 ? (
            <div className="notice warn">
              <strong>Can't issue yet.</strong> {data.build.name} is short:{' '}
              {short.map((c) => `${c.item.name} (needs ${qty(c.qty_required, c.item.uom)}, has ${qty(data.stock.get(c.item_id) ?? 0, c.item.uom)})`).join('; ')}.{' '}
              <Link to="/mrp">MRP</Link> shows what to order.
            </div>
          ) : (
            <p className="muted">Issuing takes every component out of {data.build.name} at its weighted-average cost and moves the value into Work in process. The start time is recorded.</p>
          )}
          <div className="page-actions">
            <label className="inline">
              Start time
              <input type="datetime-local" value={startAt} onChange={(e) => setStartAt(e.target.value)} />
            </label>
            <button
              className="btn primary"
              disabled={busy !== null || short.length > 0}
              onClick={() => act('issue', 'issue_production_order', { p_mo_id: mo.id, p_at: new Date(startAt).toISOString() }, `${mo.mo_no} issued: components consumed, order in progress.`)}
            >
              {busy === 'issue' ? 'Issuing…' : 'Issue components & start'}
            </button>
            {!cancelling ? (
              <button className="btn" disabled={busy !== null} onClick={() => setCancelling(true)}>Cancel order…</button>
            ) : (
              <form
                className="inline-form"
                onSubmit={(e) => {
                  e.preventDefault();
                  void act('cancel', 'cancel_production_order', { p_mo_id: mo.id, p_reason: cancelReason.trim() || null }, `${mo.mo_no} cancelled.`);
                }}
              >
                <input value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="Reason" autoFocus />
                <button className="btn danger" disabled={busy !== null}>Confirm cancel</button>
                <button type="button" className="btn link" onClick={() => setCancelling(false)}>Keep order</button>
              </form>
            )}
          </div>
        </div>
      )}

      {mo.status === 'in_progress' && (
        <form
          className="card action-card"
          onSubmit={(e) => {
            e.preventDefault();
            void act(
              'complete',
              'complete_production_order',
              { p_mo_id: mo.id, p_qty_good: goodN, p_qty_scrap: scrapN, p_scrap_reason: needReason ? scrapReason : null, p_at: new Date(finishAt).toISOString() },
              `${mo.mo_no} completed: ${goodN} good received into ${data.output.name}${scrapN > 0 ? `, ${scrapN} scrapped` : ''}.`,
            );
          }}
        >
          <p className="muted">
            Record what came off the printer. Good + scrapped must equal the {qty(started)} started. Good units go into {data.output.name} at the rolled-up cost; scrapped units' cost is
            expensed as production scrap (cost of poor quality).
          </p>
          <div className="form-row">
            <label>
              Good units
              <input type="number" min={0} max={started} step={1} value={good === '' ? String(started) : good} onChange={(e) => setGood(e.target.value)} />
            </label>
            <label>
              Scrapped / reworked
              <input value={goodValid ? scrapN : '—'} readOnly tabIndex={-1} />
            </label>
            <label className="grow">
              Scrap reason {needReason && <span className="bad">(required)</span>}
              <select value={scrapReason} onChange={(e) => setScrapReason(e.target.value)} disabled={!needReason} required={needReason}>
                <option value="">{needReason ? 'Choose a quality reason…' : 'No scrap'}</option>
                {(ref.data?.scrapReasons ?? []).map((r) => (
                  <option key={r.code} value={r.code}>{r.description}</option>
                ))}
              </select>
            </label>
            <label>
              Finish time
              <input type="datetime-local" value={finishAt} onChange={(e) => setFinishAt(e.target.value)} />
            </label>
          </div>
          <div className="page-actions">
            <button className="btn primary" disabled={busy !== null || !goodValid || (needReason && !scrapReason)}>
              {busy === 'complete' ? 'Completing…' : 'Complete order'}
            </button>
          </div>
        </form>
      )}

      {mo.status === 'in_progress' && <ReportFailure mo={mo} reasons={ref.data?.scrapReasons ?? []} />}

      {result && <div className={`notice ${result.ok ? 'ok' : 'error'} spaced`}>{result.text}</div>}

      <div className="detail-grid">
        <div>
          <h2>Components (bill of material × {mo.plates} plates)</h2>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Component</th>
                  <th className="num">Required</th>
                  <th className="num">Issued</th>
                  {mo.status === 'planned' ? <th className="num">On hand</th> : <th className="num">Unit cost</th>}
                  <th className="num">Cost</th>
                </tr>
              </thead>
              <tbody>
                {components.map((c) => (
                  <tr key={c.item_id}>
                    <td><Link to={`/inventory/item/${c.item_id}`}>{c.item.name}</Link></td>
                    <td className="num">{qty(c.qty_required, c.item.uom)}</td>
                    <td className="num">{qty(c.qty_issued, c.item.uom)}</td>
                    {mo.status === 'planned' ? (
                      <td className={`num ${short.some((x) => x.item_id === c.item_id) ? 'bad strong' : ''}`}>{qty(data.stock.get(c.item_id) ?? 0, c.item.uom)}</td>
                    ) : (
                      <td className="num">{c.unit_cost === null ? '—' : unitCost(c.unit_cost)}</td>
                    )}
                    <td className="num">{c.unit_cost === null ? '—' : money(Number(c.qty_issued) * Number(c.unit_cost))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <dl className="facts">
            <dt>Due</dt>
            <dd>{date(mo.due_date)}</dd>
            <dt>Output to</dt>
            <dd>{data.output.name}</dd>
            {data.so && (
              <>
                <dt>For sales order</dt>
                <dd><Link to={`/sales/${data.so.id}`}>{data.so.order_no}</Link></dd>
              </>
            )}
            {mo.notes && (
              <>
                <dt>Notes</dt>
                <dd>{mo.notes}</dd>
              </>
            )}
          </dl>
        </div>
        <div>
          <h2>Cost roll-up</h2>
          <div className="card">
            {mo.status === 'planned' || mo.status === 'cancelled' ? (
              <p className="muted">
                Nothing costed yet. Standard cost today: {std ? `${unitCost(std.total_cost)} per unit` : '—'} (materials {std ? unitCost(std.material_cost) : '—'}, machine{' '}
                {std ? unitCost(std.machine_cost) : '—'}, labor {std ? unitCost(std.labor_cost) : '—'}).
              </p>
            ) : (
              <table className="totals">
                <tbody>
                  <tr>
                    <td>Materials issued<div className="muted small">components at weighted-average cost</div></td>
                    <td className="num">{money(mo.material_cost)}</td>
                  </tr>
                  <tr>
                    <td>
                      Machine time
                      <div className="muted small">{mo.plates} plates × {printHours.toFixed(2)} h × {unitCost(ref.data?.machineRate ?? 0)}/h</div>
                    </td>
                    <td className="num">{mo.status === 'completed' ? money(mo.machine_cost) : <span className="muted">at completion</span>}</td>
                  </tr>
                  <tr>
                    <td>
                      Labor
                      <div className="muted small">{mo.plates} plates × {perPlateMin} min (setup, cleanup, assembly) × {money(laborRate)}/h</div>
                    </td>
                    <td className="num">{mo.status === 'completed' ? money(mo.labor_cost) : <span className="muted">at completion</span>}</td>
                  </tr>
                  {mo.status === 'completed' && (
                    <>
                      <tr className="grand">
                        <td>Total ÷ {qty(mo.qty_started)} started</td>
                        <td className="num">{money(Number(mo.material_cost) + Number(mo.machine_cost) + Number(mo.labor_cost))}</td>
                      </tr>
                      <tr>
                        <td className="strong">Rolled-up unit cost</td>
                        <td className="num strong">{unitCost(mo.unit_cost)}</td>
                      </tr>
                      <tr>
                        <td>{qty(mo.qty_good)} good → inventory</td>
                        <td className="num">{money(Number(mo.qty_good) * Number(mo.unit_cost))}</td>
                      </tr>
                      {Number(mo.qty_scrap) > 0 && (
                        <tr>
                          <td className="bad">
                            {qty(mo.qty_scrap)} scrapped → production scrap
                            <div className="small">{ref.data?.scrapReasons.find((r) => r.code === mo.scrap_reason)?.description ?? mo.scrap_reason}</div>
                          </td>
                          <td className="num bad">{money(Number(mo.qty_scrap) * Number(mo.unit_cost))}</td>
                        </tr>
                      )}
                    </>
                  )}
                </tbody>
              </table>
            )}
          </div>
          <dl className="facts">
            <dt>Created</dt>
            <dd>{dateTime(mo.created_at)}</dd>
            <dt>Started</dt>
            <dd>{dateTime(mo.started_at)}</dd>
            <dt>Finished</dt>
            <dd>{dateTime(mo.finished_at)}</dd>
            {mo.started_at && mo.finished_at && (
              <>
                <dt>Cycle time</dt>
                <dd>{hoursText((new Date(mo.finished_at).getTime() - new Date(mo.started_at).getTime()) / 3600000)}</dd>
              </>
            )}
          </dl>
        </div>
      </div>

      <JournalTables
        ledger={data.ledger}
        accounts={data.accounts}
        names={{ production_issue: 'Issue to production', production_complete: 'Production complete' }}
        empty={mo.status === 'planned' ? 'Nothing is posted until the order is issued.' : 'Cancelled before issue: nothing was posted.'}
      />
    </div>
  );
}

function Steps({ mo }: { mo: ProductionOrder }) {
  const steps =
    mo.status === 'cancelled'
      ? [
          { label: 'Planned', at: mo.created_at, done: true },
          { label: 'Cancelled', at: null as string | null, done: true },
        ]
      : [
          { label: 'Planned', at: mo.created_at, done: true },
          { label: 'Issued (in progress)', at: mo.started_at, done: mo.started_at !== null },
          { label: 'Completed', at: mo.finished_at, done: mo.finished_at !== null },
        ];
  return (
    <div className="steps-wrap">
      <ol className={`steps ${mo.status}`}>
        {steps.map((s) => (
          <li key={s.label} className={s.done ? 'done' : ''}>
            <span className="step-label">{s.label}</span>
            <span className="muted small">{s.done ? (s.at ? dateTime(s.at) : '') : 'Not yet'}</span>
          </li>
        ))}
      </ol>
      <MoStatusBadge status={mo.status} />
    </div>
  );
}

/**
 * Wow factor #2: one click when a print fails on the printer. The database
 * scraps the failed units (cost of poor quality), creates the reprint for the
 * same sales order and starts it if components are on hand; the customer's
 * tracking page moves back to "Printing" by itself.
 */
function ReportFailure({ mo, reasons }: { mo: ProductionOrder; reasons: ReasonCode[] }) {
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [failed, setFailed] = useState(String(Number(mo.qty_started)));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const started = Number(mo.qty_started);
  const n = Number(failed);
  const ok = Number.isInteger(n) && n >= 1 && n <= started && reason !== '';

  async function submit() {
    setBusy(true);
    setErr(null);
    try {
      const id = await rpc<string>('report_print_failure', { p_mo_id: mo.id, p_reason: reason, p_qty_failed: n });
      navigate(`/production/${id}`);
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    return (
      <div className="spaced">
        <button className="btn danger" onClick={() => setOpen(true)}>Report print failure…</button>
      </div>
    );
  }
  return (
    <form className="card action-card failure-card" onSubmit={(e) => { e.preventDefault(); void submit(); }}>
      <h2 style={{ margin: 0 }}>Report print failure</h2>
      <p className="muted">
        Scraps the failed units now (their filament, machine time and labor go to production scrap on the P&amp;L), then creates a reprint for the same
        {mo.so_id ? ' sales order' : ' quantity'} and starts it if the components are on hand. Units that printed fine still go into stock.
      </p>
      <div className="form-row">
        <label className="grow">
          What went wrong
          <select value={reason} onChange={(e) => setReason(e.target.value)} required autoFocus>
            <option value="">Choose a failure reason…</option>
            {reasons.map((r) => <option key={r.code} value={r.code}>{r.description}</option>)}
          </select>
        </label>
        <label>
          Units failed (of {started})
          <input type="number" min={1} max={started} step={1} value={failed} onChange={(e) => setFailed(e.target.value)} />
        </label>
      </div>
      {err && <div className="notice error">{err}</div>}
      <div className="page-actions">
        <button className="btn danger" disabled={!ok || busy}>{busy ? 'Recording…' : 'Scrap & reprint'}</button>
        <button type="button" className="btn link" onClick={() => setOpen(false)}>Never mind</button>
      </div>
    </form>
  );
}
