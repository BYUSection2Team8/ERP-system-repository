import { useState } from 'react';
import { db, unwrap } from '../../lib/db';
import { dateTime } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { QrCode } from './QrCode';
import { emailConfigured, sendTrackingEmail, trackingUrl, validEmail, type EmailResult } from './tracking';

interface EmailLogRow {
  id: number;
  to_email: string;
  status: 'sent' | 'failed' | 'skipped';
  error: string | null;
  sent_at: string;
}

/**
 * "Track your order" box: private link + QR code (the safety net if an email
 * lands in spam), and a button that emails the link. Staff also see every
 * email attempt for the order.
 */
export function TrackingCard({
  soId,
  token,
  orderNo,
  defaultEmail,
  toName,
  showLog = true,
  compact = false,
}: {
  soId: string;
  token: string | null;
  orderNo: string;
  defaultEmail?: string | null;
  toName?: string | null;
  showLog?: boolean;
  compact?: boolean;
}) {
  const [email, setEmail] = useState(defaultEmail ?? '');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<EmailResult | null>(null);
  const [copied, setCopied] = useState(false);
  const log = useLiveQuery(
    async () => (showLog ? unwrap<EmailLogRow[]>(await db().from('email_log').select('*').eq('so_id', soId).order('sent_at', { ascending: false })) : []),
    showLog ? ['email_log'] : [],
    [soId, showLog],
  );
  if (!token) return null;
  const url = trackingUrl(token);

  async function send() {
    setBusy(true);
    setResult(null);
    setResult(await sendTrackingEmail({ soId, to: email, toName, orderNo, token: token as string }));
    setBusy(false);
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      window.prompt('Copy the tracking link:', url);
    }
  }

  return (
    <div className={`card tracking-card ${compact ? 'compact' : ''}`}>
      <QrCode value={url} size={compact ? 110 : 132} label={`QR code: track order ${orderNo}`} />
      <div className="tracking-body">
        <h2 style={{ margin: 0 }}>Live order tracking</h2>
        <p className="muted small" style={{ margin: 0 }}>
          Scan the QR code or open the private link: stage, % printed and the ready / delivery date, no login needed.
        </p>
        <div className="inline-form">
          <a className="btn" href={url} target="_blank" rel="noreferrer">Open tracking page</a>
          <button type="button" className="btn" onClick={copy}>{copied ? 'Copied ✓' : 'Copy link'}</button>
        </div>
        <form
          className="inline-form no-print"
          onSubmit={(e) => {
            e.preventDefault();
            void send();
          }}
        >
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="customer@example.com" aria-label="Customer email" />
          <button className="btn primary" disabled={busy || !validEmail(email)}>{busy ? 'Sending…' : 'Email tracking link'}</button>
        </form>
        {!emailConfigured && <div className="muted small no-print">Email sending is not set up yet; attempts are logged as "not sent". The link and QR code always work.</div>}
        {result && <div className={`notice ${result.status === 'sent' ? 'ok' : result.status === 'failed' ? 'error' : 'warn'} small`}>{result.message}</div>}
        {showLog && log.data && log.data.length > 0 && (
          <ul className="email-log small no-print">
            {log.data.map((r) => (
              <li key={r.id}>
                <span className={`badge ${r.status === 'sent' ? 'ok' : r.status === 'failed' ? 'bad' : 'warn'}`}>{r.status === 'skipped' ? 'not sent' : r.status}</span>{' '}
                {r.to_email} · {dateTime(r.sent_at)}
                {r.error && r.status === 'failed' && <div className="muted">{r.error}</div>}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
