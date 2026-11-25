import { useState } from 'react';
import { ErrorNotice, Loading, Stat } from '../../app/ui';
import { rpc } from '../../lib/db';
import { date, money } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { addDays, localToday, pctText } from '../production/productionShared';
import { BarChart, DateRange, shortDate } from './reportsShared';

// Demand patterns (migration 024): counted by the day an order was PLACED, so the
// weekday, game-day and holiday patterns show. (Sales by day counts the day an
// order shipped, which follows the shipping schedule instead.)

interface Patterns {
  weekday: { dow: number; days: number; orders: number; per_day: number }[] | null;
  monthly: { month: string; segment: string; orders: number; sales: number }[] | null;
  families: { month: string; family: string; units: number }[] | null;
  game: { game_days: number; game_per_day: number | null; other_days: number; other_per_day: number | null } | null;
  byu_blue: { game: number | null; other: number | null } | null;
  events: { label: string; date: string; orders: number; november_avg: number | null }[] | null;
  daily: { d: string; orders: number; sales: number }[] | null;
}

const dowNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const segNames: Record<string, string> = {
  student: 'Students',
  gift_buyer: 'Gift buyers',
  hobbyist: 'Hobbyists',
  local_family: 'Local families',
  business: 'Businesses',
  walk_in: 'Walk-in (campus counter)',
};
const segOrder = ['student', 'walk_in', 'gift_buyer', 'local_family', 'hobbyist', 'business'];
const monthLabel = (m: string) => new Date(`${m}-15T12:00:00`).toLocaleDateString('en-US', { month: 'short', year: '2-digit' });
const x = (a: number | null | undefined, b: number | null | undefined) =>
  a && b ? `${(Number(a) / Number(b)).toFixed(1)}×` : '—';

export function PatternsReport() {
  const today = localToday();
  const [from, setFrom] = useState(addDays(today, -182));
  const [to, setTo] = useState(today);
  const { data, error, loading } = useLiveQuery(
    () => rpc<Patterns>('demand_patterns', { p_from: from, p_to: to }),
    ['sales_orders'],
    [from, to],
  );

  if (error && /demand_patterns|function|schema cache/i.test(error)) {
    return <div className="notice warn">This report needs migration 024 (the Demo database). It is not set up on this database.</div>;
  }

  const weekday = [...(data?.weekday ?? [])].sort((a, b) => ((a.dow + 6) % 7) - ((b.dow + 6) % 7));
  const months = [...new Set((data?.monthly ?? []).map((m) => m.month))].sort();
  const segs = segOrder.filter((s) => (data?.monthly ?? []).some((m) => m.segment === s));
  const cell = (month: string, seg: string) => data?.monthly?.find((m) => m.month === month && m.segment === seg)?.orders ?? 0;
  // Life cycle: only months fully inside the range (a 5-day first month or a
  // half-finished last month would make the comparison misleading).
  const fullMonth = (m: string) => {
    const [y, mo] = m.split('-').map(Number);
    const days = new Date(Date.UTC(y, mo, 0)).getUTCDate(); // last day of month mo
    return `${m}-01` >= from && `${m}-${String(days).padStart(2, '0')}` <= to;
  };
  const famMonths = [...new Set((data?.families ?? []).map((f) => f.month))].sort().filter(fullMonth);
  const share = (month: string, fam: string) => {
    const rows = (data?.families ?? []).filter((f) => f.month === month);
    const total = rows.reduce((s, r) => s + Number(r.units), 0);
    return total ? Number(rows.find((r) => r.family === fam)?.units ?? 0) / total : 0;
  };
  const sun = weekday.find((w) => w.dow === 0)?.per_day;
  const mon = weekday.find((w) => w.dow === 1)?.per_day;
  const sat = weekday.find((w) => w.dow === 6)?.per_day;
  const bf = data?.events?.find((e) => e.label === 'Black Friday');

  return (
    <>
      <DateRange from={from} to={to} today={today} onChange={(f, t) => { setFrom(f); setTo(t); }} />
      <p className="muted small">
        Counted by the day each order was <strong>placed</strong> (exchanges and cancelled orders left out). Sales by day counts the day an order
        shipped, which follows the shipping schedule (weekdays, Tue/Fri campus runs) instead of customer behavior.
      </p>
      {loading && <Loading what="demand patterns" />}
      {error && <ErrorNotice message={error} />}
      {data && (
        <>
          <div className="stats">
            <Stat label="Sun + Mon vs Saturday" value={x(((Number(sun) || 0) + (Number(mon) || 0)) / 2, sat)} hint="Online orders peak Sunday/Monday evenings" />
            <Stat
              label="BYU home game days"
              value={x(data.game?.game_per_day, data.game?.other_per_day)}
              hint={data.game?.game_days ? `${data.game.game_per_day} vs ${data.game.other_per_day} orders/day (Sep–Nov)` : 'No game days in this range'}
            />
            <Stat
              label="Blue share of BYU logos"
              value={data.byu_blue?.game != null ? `${pctText(data.byu_blue.game, 0)} vs ${pctText(data.byu_blue.other, 0)}` : '—'}
              hint="Game days vs other days"
            />
            <Stat
              label="Black Friday"
              value={bf ? `${bf.orders} orders` : '—'}
              hint={bf ? `${x(bf.orders, bf.november_avg)} a normal November day (${bf.november_avg})` : 'Not in this range yet'}
            />
          </div>

          <div className="pattern-grid">
            <div>
              <h2>Orders per day, by weekday</h2>
              <BarChart
                title="Average orders per day by weekday"
                format={(v) => v.toFixed(1)}
                bars={weekday.map((w) => ({ key: String(w.dow), label: dowNames[w.dow], value: Number(w.per_day), tooltip: `${dowNames[w.dow]}: ${w.per_day} orders/day (${w.orders} orders over ${w.days} days)` }))}
              />
            </div>
            <div>
              <h2>Product life cycle</h2>
              <BarChart
                title="Dragon share of units sold by month"
                format={(v) => `${Math.round(v * 100)}%`}
                bars={famMonths.map((m) => ({ key: m, label: monthLabel(m), value: share(m, 'Dragon'), tooltip: `${monthLabel(m)}: Dragons ${pctText(share(m, 'Dragon'))}, Fidget Spinners ${pctText(share(m, 'Fidget Spinner'))} of units` }))}
              />
              <p className="muted small">
                Dragons {pctText(share(famMonths[0] ?? '', 'Dragon'), 0)} → {pctText(share(famMonths[famMonths.length - 1] ?? '', 'Dragon'), 0)} of units;
                Fidget Spinners {pctText(share(famMonths[0] ?? '', 'Fidget Spinner'), 0)} → {pctText(share(famMonths[famMonths.length - 1] ?? '', 'Fidget Spinner'), 0)}.
              </p>
            </div>
          </div>

          <h2>Orders placed per day</h2>
          <BarChart
            title="Orders placed per day"
            format={(v) => v.toFixed(0)}
            bars={(data.daily ?? []).map((d) => ({ key: d.d, label: shortDate(d.d), value: Number(d.orders), tooltip: `${shortDate(d.d)}: ${d.orders} orders, ${money(d.sales)}` }))}
          />

          <h2>Orders by month and customer type</h2>
          <p className="muted small">Students fade in summer and surge at back-to-school; gift buyers ramp up for the holidays; local families buy most in summer.</p>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Customer type</th>
                  {months.map((m) => <th key={m} className="num">{monthLabel(m)}</th>)}
                </tr>
              </thead>
              <tbody>
                {segs.map((s) => (
                  <tr key={s}>
                    <td>{segNames[s] ?? s}</td>
                    {months.map((m) => <td key={m} className="num">{cell(m, s)}</td>)}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {(data.events ?? []).length > 0 && (
            <>
              <h2>Thanksgiving week</h2>
              <div className="table-wrap">
                <table className="table">
                  <thead><tr><th>Day</th><th>Date</th><th className="num">Orders</th><th className="num">vs a normal November day</th></tr></thead>
                  <tbody>
                    {(data.events ?? []).map((e) => (
                      <tr key={e.label}>
                        <td>{e.label}</td>
                        <td>{date(e.date)}</td>
                        <td className="num">{e.orders}</td>
                        <td className="num">{x(e.orders, e.november_avg)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </>
      )}
    </>
  );
}
