import { useState } from 'react';
import { Link } from 'react-router-dom';
import { errorMessage, rpc } from '../../lib/db';
import { money } from '../../lib/format';

interface SimResult {
  days: number;
  event: string | null;
  orders: number;
  units: number;
  value: number;
  expected_units: number;
  units_per_order: number;
}

/**
 * Demand simulator (wow factor #8): creates the orders the next day(s) would
 * bring, from the last 28 days of sales x weekday pattern x event. The orders
 * are real "Order placed" orders, so stock, backorders, MRP and the dashboard react.
 */
export function DemandSimulator() {
  const [days, setDays] = useState('1');
  const [event, setEvent] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<SimResult | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function run() {
    if (!window.confirm(`Create the orders ${days === '1' ? 'tomorrow' : `the next ${days} days`} would bring${event ? ` (${event.replace('_', ' ')})` : ''}? They are real orders marked [Simulated demand].`)) return;
    setBusy(true);
    setErr(null);
    try {
      setResult(await rpc<SimResult>('simulate_demand', { p_days: Number(days), p_event: event || null }));
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="card action-card">
      <h2 style={{ margin: 0 }}>Demand simulator</h2>
      <p className="muted small">
        Uses the last 28 days of sales per item × the weekday pattern of the last 8 weeks × the event, with Poisson randomness, then groups units into orders of the usual size
        for random customers (about 80% shipped, 20% campus pickup). Watch backorders, MRP and the printer queue react.
      </p>
      <div className="inline-form">
        <select value={days} onChange={(e) => setDays(e.target.value)} aria-label="Days to simulate">
          {[1, 2, 3, 5, 7].map((d) => <option key={d} value={d}>{d === 1 ? 'Next day' : `Next ${d} days`}</option>)}
        </select>
        <select value={event} onChange={(e) => setEvent(e.target.value)} aria-label="Event">
          <option value="">Normal demand</option>
          <option value="byu_game">BYU home game (BYU Logo & blue ×2)</option>
          <option value="black_friday">Black Friday (×2.5)</option>
          <option value="slow">Slow week (×0.5)</option>
        </select>
        <button className="btn primary" disabled={busy} onClick={run}>{busy ? 'Simulating…' : 'Simulate'}</button>
      </div>
      {err && <div className="notice error">{err}</div>}
      {result && (
        <div className="notice ok">
          {result.orders} orders · {result.units} units · {money(result.value)} (expected {Number(result.expected_units).toFixed(1)} units, about{' '}
          {Number(result.units_per_order).toFixed(1)} per order). <Link to="/sales">See the orders</Link> · <Link to="/mrp">MRP</Link> ·{' '}
          <Link to="/inventory/backorders">Backorders</Link>
        </div>
      )}
    </div>
  );
}
