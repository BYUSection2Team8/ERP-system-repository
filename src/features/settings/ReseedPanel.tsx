import { useEffect, useState } from 'react';
import { errorMessage, rpc } from '../../lib/db';
import { date } from '../../lib/format';
import { dbShortLabel } from '../../lib/supabase';

interface Status {
  allowed: boolean;
  start: string | null;
  through: string | null;
  complete: boolean;
  yesterday: string;
}
interface Step {
  done: boolean;
  start: string | null;
  through: string | null;
  end: string | null;
}

const dayNo = (iso: string) => Math.round(new Date(`${iso}T12:00:00`).getTime() / 86400000);

/**
 * "Reseed data through yesterday" (migration 024). Wipes every order, stock
 * movement and ledger entry and regenerates ~6 months of simulated history in
 * short chunks. Hidden on a database without migration 024 (reseed_status is
 * missing there) and disabled when the setting allow_reseed is false.
 */
export function ReseedPanel() {
  const [status, setStatus] = useState<Status | null>(null);
  const [confirm, setConfirm] = useState('');
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<{ start: string; through: string | null; end: string } | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  async function refresh() {
    try {
      setStatus(await rpc<Status>('reseed_status', {}));
    } catch {
      setStatus(null); // database 1 (no migration 024): no reseed here
    }
  }
  useEffect(() => {
    void refresh();
  }, []);

  if (!status) return null;

  async function run() {
    setRunning(true);
    setMsg(null);
    try {
      const begun = await rpc<Status>('reseed_begin', {});
      let step: Step = { done: false, start: begun.start, through: null, end: begun.yesterday };
      for (let i = 0; i < 400 && !step.done; i++) {
        step = await rpc<Step>('reseed_step', {});
        if (step.start && step.end) setProgress({ start: step.start, through: step.through, end: step.end });
      }
      if (!step.done) throw new Error('The reseed stopped before finishing. Press the button again to continue.');
      setMsg({ ok: true, text: `Done: history regenerated from ${date(step.start)} through ${date(step.end)}. Every screen now shows the new data.` });
      setConfirm('');
    } catch (e) {
      setMsg({ ok: false, text: `${errorMessage(e)} (If it stopped part-way, press the button again: it continues where it stopped.)` });
    } finally {
      setRunning(false);
      void refresh();
    }
  }

  // A reseed that stopped part-way can simply be continued.
  async function resume() {
    setRunning(true);
    setMsg(null);
    try {
      let step: Step = { done: false, start: status!.start, through: status!.through, end: status!.yesterday };
      for (let i = 0; i < 400 && !step.done; i++) {
        step = await rpc<Step>('reseed_step', {});
        if (step.start && step.end) setProgress({ start: step.start, through: step.through, end: step.end });
      }
      setMsg({ ok: step.done, text: step.done ? 'Done: history complete.' : 'Still not finished: press Continue again.' });
    } catch (e) {
      setMsg({ ok: false, text: errorMessage(e) });
    } finally {
      setRunning(false);
      void refresh();
    }
  }

  const pct = progress && progress.through
    ? Math.min(100, Math.max(0, ((dayNo(progress.through) - dayNo(progress.start) + 1) / (dayNo(progress.end) - dayNo(progress.start) + 1)) * 100))
    : running ? 2 : 0;

  return (
    <section>
      <h2>Simulated history ({dbShortLabel})</h2>
      <div className="card" style={{ display: 'flex', flexDirection: 'column', gap: '0.6rem' }}>
        <p style={{ margin: 0 }}>
          History: {status.start ? `${date(status.start)} → ${status.through ? date(status.through) : '…'}` : 'none'}
          {status.complete ? ' (complete)' : ' (not finished)'}. Yesterday was {date(status.yesterday)}.
        </p>
        <p className="muted small" style={{ margin: 0 }}>
          <strong>Reseed data through yesterday</strong> deletes every order, return, production order, purchase order, bill, stock movement and ledger
          entry, and products made in the app (custom quotes, new designs), then simulates about 6 months of business again, ending yesterday.
          Logins, products, suppliers, prices and settings stay. It takes a minute or two; keep this page open.
        </p>
        {!status.allowed ? (
          <div className="notice warn">Reseeding is turned off (System → “Allow Reseed data” = false).</div>
        ) : (
          <>
            {!status.complete && status.start && !running && (
              <div className="notice warn">
                The last reseed did not finish.{' '}
                <button className="btn" onClick={() => void resume()}>Continue it</button>
              </div>
            )}
            <div className="toolbar">
              <label>
                Type RESEED to confirm
                <input value={confirm} onChange={(e) => setConfirm(e.target.value)} disabled={running} placeholder="RESEED" />
              </label>
              <button className="btn danger" style={{ alignSelf: 'flex-end' }} disabled={running || confirm.trim() !== 'RESEED'} onClick={() => void run()}>
                {running ? 'Reseeding…' : 'Reseed data through yesterday'}
              </button>
            </div>
          </>
        )}
        {(running || progress) && (
          <div>
            <div className="score-bar" style={{ height: 10 }}>
              <span style={{ width: `${pct}%` }} />
            </div>
            <div className="muted small">
              {progress?.through ? `Simulated through ${date(progress.through)} of ${date(progress.end)}` : 'Clearing the old data…'}
            </div>
          </div>
        )}
        {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'}`}>{msg.text}</div>}
      </div>
    </section>
  );
}
