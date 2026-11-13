import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Logo } from '../../app/Logo';
import { errorMessage, rpc } from '../../lib/db';
import { date, dateTime, money } from '../../lib/format';
import type { Tracking } from './tracking';

// Public order tracking page: /#/track/<token>. No login. The database
// function track_order(token) returns only this order's progress (no address,
// email or payment details). Refreshes every 20 seconds; the countdown ticks
// every second.

function countdown(ms: number): string {
  if (ms <= 0) return 'any minute now';
  const m = Math.floor(ms / 60000);
  const h = Math.floor(m / 60);
  const d = Math.floor(h / 24);
  if (d >= 1) return `${d} day${d === 1 ? '' : 's'} ${h % 24} h`;
  if (h >= 1) return `${h} h ${m % 60} min`;
  return `${m} min ${Math.floor((ms % 60000) / 1000)} s`;
}

export function TrackPage() {
  const { token = '' } = useParams();
  const [t, setT] = useState<Tracking | null>(null);
  const [state, setState] = useState<'loading' | 'ok' | 'missing' | 'error'>('loading');
  const [err, setErr] = useState('');
  const [now, setNow] = useState(Date.now());

  const load = useCallback(async () => {
    try {
      const r = await rpc<Tracking | null>('track_order', { p_token: token });
      setT(r);
      setState(r ? 'ok' : 'missing');
    } catch (e) {
      setErr(errorMessage(e));
      setState('error');
    }
  }, [token]);

  useEffect(() => {
    void load();
    const poll = window.setInterval(() => void load(), 20000);
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => {
      window.clearInterval(poll);
      window.clearInterval(tick);
    };
  }, [load]);

  const progress = t?.progress !== null && t?.progress !== undefined && t.ready_at
    ? Math.min(0.99, Math.max(Number(t.progress), (now - new Date(t.checked_at).getTime()) / Math.max(1, new Date(t.ready_at).getTime() - new Date(t.checked_at).getTime()) * (1 - Number(t.progress)) + Number(t.progress)))
    : null;

  return (
    <div className="login-screen track-screen">
      <div className="login-card track-card">
        <div className="login-brand">
          <Logo size={40} />
          <div>
            <h1>{t?.company ?? 'Poulson Prints'}</h1>
            <p className="muted">Order tracking</p>
          </div>
        </div>
        {state === 'loading' && <p className="muted">Looking up your order…</p>}
        {state === 'missing' && <p>We could not find that order. Please check the link in your email or receipt.</p>}
        {state === 'error' && (
          <div className="notice error">
            Tracking is temporarily unavailable. Please try again in a few minutes.
            <div className="small muted" style={{ marginTop: 4 }}>{err}</div>
          </div>
        )}
        {t && (
          <>
            <div>
              <div className="muted small">{t.first_name ? `Hi ${t.first_name}! ` : ''}Order {t.order_no} · placed {date(t.order_date)}</div>
              <div className={`track-stage ${t.stage}`}>{t.stage_label}</div>
              <p style={{ margin: '0.25rem 0 0' }}>{t.stage_detail}</p>
            </div>
            {t.stage === 'printing' && progress !== null && t.ready_at && (
              <div>
                <div className="progress" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(progress * 100)}>
                  <span style={{ width: `${Math.round(progress * 100)}%` }} />
                </div>
                <div className="small muted" style={{ marginTop: 4 }}>
                  {Math.round(progress * 100)}% printed · done in about <strong>{countdown(new Date(t.ready_at).getTime() - now)}</strong>
                </div>
              </div>
            )}
            {(t.ready_date || t.est_delivery_date) && !['picked_up', 'delivered', 'cancelled'].includes(t.stage) && (
              <div className="track-eta">
                {t.fulfillment_method === 'ship' ? 'Estimated delivery' : 'Ready for pickup'}
                <strong>{date(t.fulfillment_method === 'ship' ? (t.est_delivery_date ?? t.ready_date) : t.ready_date)}</strong>
                {t.fulfillment_method !== 'ship' && <span className="muted small">at {t.location_name}</span>}
              </div>
            )}
            <ol className="track-steps">
              {t.steps.map((s) => (
                <li key={s.key} className={s.done ? 'done' : t.stage === 'cancelled' ? 'off' : ''}>
                  <span className="track-dot" aria-hidden="true" />
                  <span>{s.label}</span>
                  {s.at && <span className="muted small">{dateTime(s.at)}</span>}
                </li>
              ))}
            </ol>
            <table className="totals">
              <tbody>
                {t.lines.map((l, i) => (
                  <tr key={i}>
                    <td>
                      {l.name}
                      {Number(l.backordered) > 0 && <div className="small muted">{Number(l.backordered)} being made · about {date(l.est_available_date)}</div>}
                    </td>
                    <td className="num">× {Number(l.qty)}</td>
                  </tr>
                ))}
                <tr className="grand">
                  <td>Total</td>
                  <td className="num">{money(t.total)}</td>
                </tr>
              </tbody>
            </table>
            <p className="muted small" style={{ margin: 0 }}>Updated {dateTime(t.checked_at)}. This page refreshes by itself.</p>
          </>
        )}
      </div>
    </div>
  );
}
