import { useState } from 'react';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { date, money } from '../../lib/format';
import type { PlLine } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { addDays, localToday } from '../production/productionShared';

interface Balance {
  code: string;
  name: string;
  type: string;
  total_debit: number;
  total_credit: number;
  balance: number;
}

function monthStart(iso: string, back = 0): string {
  const [y, m] = iso.split('-').map(Number);
  const d = new Date(Date.UTC(y, m - 1 - back, 1));
  return d.toISOString().slice(0, 10);
}
function monthEnd(iso: string, back = 0): string {
  return addDays(monthStart(iso, back - 1), -1);
}
function monthLabel(iso: string): string {
  return new Date(`${iso}T12:00:00`).toLocaleDateString('en-US', { month: 'short', year: '2-digit' });
}

const pl = (from: string, to: string) => db().rpc('pl_report', { p_from: from, p_to: to }).then((r) => unwrap<PlLine[]>(r));

async function load(from: string, to: string, today: string) {
  const months = [5, 4, 3, 2, 1, 0].map((b) => ({ from: monthStart(today, b), to: b === 0 ? today : monthEnd(today, b) }));
  const [period, trend, balances] = await Promise.all([
    pl(from, to),
    Promise.all(months.map((m) => pl(m.from, m.to).then((lines) => ({ ...m, lines })))),
    db().from('v_account_balances').select('*').then(unwrap<Balance[]>),
  ]);
  return { period, trend, balances };
}

export function ProfitLossPage() {
  const today = localToday();
  const presets = [
    { label: 'This month', from: monthStart(today), to: today },
    { label: 'Last month', from: monthStart(today, 1), to: monthEnd(today, 1) },
    { label: 'Last 30 days', from: addDays(today, -29), to: today },
    { label: 'Last 6 months', from: monthStart(today, 5), to: today },
    { label: 'Year to date', from: `${today.slice(0, 4)}-01-01`, to: today },
  ];
  const [from, setFrom] = useState(presets[3].from);
  const [to, setTo] = useState(today);
  const { data, error, loading } = useLiveQuery(() => load(from, to, today), ['ledger'], [from, to]);

  const amt = (lines: PlLine[], label: string) => Number(lines.find((l) => l.label === label)?.amount ?? 0);

  return (
    <div>
      <PageHeader
        title="Profit & loss"
        subtitle="Read live from the general ledger: every sale, return, receipt, production order and adjustment posts its own journal, so this report changes the moment something happens anywhere in the system."
      />
      <div className="toolbar">
        <label>
          From
          <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} />
        </label>
        <label>
          To
          <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} />
        </label>
        <div className="choice-row" style={{ alignSelf: 'flex-end' }}>
          {presets.map((p) => (
            <button key={p.label} type="button" className={`btn ${p.from === from && p.to === to ? 'primary' : ''}`} onClick={() => { setFrom(p.from); setTo(p.to); }}>
              {p.label}
            </button>
          ))}
        </div>
      </div>

      {loading && <Loading what="profit and loss" />}
      {error && <ErrorNotice message={error} />}
      {data && (() => {
        const net = amt(data.period, 'Net sales');
        const pctOf = (v: number) => (net !== 0 ? `${((v / net) * 100).toFixed(1)}%` : '');
        const dr = data.balances.reduce((s, b) => s + Number(b.total_debit), 0);
        const cr = data.balances.reduce((s, b) => s + Number(b.total_credit), 0);
        return (
          <>
            <div className="stats">
              <Stat label="Net sales" value={money(net)} hint={`${date(from)} – ${date(to)}`} />
              <Stat label="Gross profit" value={money(amt(data.period, 'Gross profit'))} hint={`${pctOf(amt(data.period, 'Gross profit'))} of net sales`} />
              <Stat label="Net income" value={money(amt(data.period, 'Net income'))} tone={amt(data.period, 'Net income') < 0 ? 'bad' : undefined} hint={`${pctOf(amt(data.period, 'Net income'))} of net sales`} />
              <Stat label="Cost of poor quality" value={money(-amt(data.period, 'Production scrap (cost of poor quality)') - amt(data.period, 'Inventory adjustments (realized losses)'))} hint="Scrap + realized inventory losses" />
            </div>

            <div className="detail-grid">
              <div className="card">
                <table className="totals pl">
                  <tbody>
                    {data.period.map((l) => (
                      <tr key={l.line_no} className={l.kind === 'total' ? 'grand' : l.kind === 'subtotal' ? 'subtotal' : ''}>
                        <td className={l.kind === 'line' ? 'indent' : 'strong'}>
                          {l.label}
                          {l.account_code && <span className="muted small"> · {l.account_code}</span>}
                        </td>
                        <td className={`num ${Number(l.amount) < 0 ? 'muted' : ''}`}>{money(l.amount)}</td>
                        <td className="num muted small">{pctOf(Number(l.amount))}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <div className="card muted small">
                <strong>Where each line comes from.</strong>
                <ul>
                  <li>Gross sales, discounts and shipping are posted when an order is fulfilled (or at the POS).</li>
                  <li>Sales returns and restocking fees are posted by returns; COGS is reversed at the original cost.</li>
                  <li>COGS = weighted-average cost of the units that left stock; packaging is a flat cost per shipped or picked-up order (Settings).</li>
                  <li>Inventory adjustments are realized losses from cycle counts, damage, loss and QA scrap; production scrap is the rolled-up cost of failed prints. Together they are the cost of poor quality.</li>
                </ul>
              </div>
            </div>

            <h2>Last 6 months</h2>
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th></th>
                    {data.trend.map((m) => <th key={m.from} className="num">{monthLabel(m.from)}{m.to === today ? ' (to date)' : ''}</th>)}
                  </tr>
                </thead>
                <tbody>
                  {data.period.map((l) => (
                    <tr key={l.line_no} className={l.kind !== 'line' ? 'strong' : ''}>
                      <td>{l.label}</td>
                      {data.trend.map((m) => <td key={m.from} className="num">{money(amt(m.lines, l.label))}</td>)}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <h2>Trial balance (all time)</h2>
            <p className="muted small">Every journal is balanced, so total debits always equal total credits.</p>
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Account</th>
                    <th className="num">Debits</th>
                    <th className="num">Credits</th>
                    <th className="num">Balance</th>
                  </tr>
                </thead>
                <tbody>
                  {data.balances.map((b) => (
                    <tr key={b.code}>
                      <td>{b.code} {b.name}</td>
                      <td className="num">{money(b.total_debit)}</td>
                      <td className="num">{money(b.total_credit)}</td>
                      <td className="num">{money(b.balance)}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr>
                    <td>Total {Math.abs(dr - cr) < 0.005 ? <span className="badge ok">balanced</span> : <span className="badge bad">out of balance</span>}</td>
                    <td className="num">{money(dr)}</td>
                    <td className="num">{money(cr)}</td>
                    <td></td>
                  </tr>
                </tfoot>
              </table>
            </div>
          </>
        );
      })()}
    </div>
  );
}
