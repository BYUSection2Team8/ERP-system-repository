import { errorMessage, rpc } from '../../lib/db';

// Live order tracking (wow factor #1): private link + QR code + email.

/** Public tracking page for a token. Works without signing in. */
export function trackingUrl(token: string): string {
  return `${window.location.origin}${window.location.pathname}#/track/${token}`;
}

const emailjs = {
  service: import.meta.env.VITE_EMAILJS_SERVICE_ID as string | undefined,
  template: import.meta.env.VITE_EMAILJS_TEMPLATE_ID as string | undefined,
  publicKey: import.meta.env.VITE_EMAILJS_PUBLIC_KEY as string | undefined,
};

export const emailConfigured = Boolean(emailjs.service && emailjs.template && emailjs.publicKey);

export function validEmail(s: string): boolean {
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s.trim());
}

export interface EmailResult {
  status: 'sent' | 'failed' | 'skipped';
  message: string;
}

/**
 * Send the "Track your order" email through EmailJS (team Gmail), then log the
 * result in the database (sent / failed / skipped). The EmailJS template uses
 * {{to_email}}, {{to_name}}, {{order_no}}, {{tracking_url}}, {{company}}.
 */
export async function sendTrackingEmail(args: {
  soId: string;
  to: string;
  toName?: string | null;
  orderNo: string;
  token: string;
  company?: string;
}): Promise<EmailResult> {
  const to = args.to.trim();
  let result: EmailResult;
  if (!emailConfigured) {
    result = { status: 'skipped', message: 'Email is not set up yet (EmailJS keys missing). Share the link or QR code instead.' };
  } else {
    try {
      const res = await fetch('https://api.emailjs.com/api/v1.0/email/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          service_id: emailjs.service,
          template_id: emailjs.template,
          user_id: emailjs.publicKey,
          template_params: {
            to_email: to,
            to_name: args.toName || 'there',
            order_no: args.orderNo,
            tracking_url: trackingUrl(args.token),
            company: args.company ?? 'Poulson Prints',
          },
        }),
      });
      result = res.ok
        ? { status: 'sent', message: `Tracking email sent to ${to}.` }
        : { status: 'failed', message: `Email failed (${res.status}): ${(await res.text()).slice(0, 200)}` };
    } catch (e) {
      result = { status: 'failed', message: `Email failed: ${errorMessage(e)}` };
    }
  }
  try {
    await rpc('log_tracking_email', { p_so_id: args.soId, p_to: to, p_status: result.status, p_error: result.status === 'sent' ? null : result.message });
  } catch (e) {
    result = { ...result, message: `${result.message} (Could not log it: ${errorMessage(e)})` };
  }
  return result;
}

export interface Tracking {
  order_no: string;
  order_date: string;
  status: string;
  fulfillment_method: 'ship' | 'pickup' | 'counter';
  location_name: string;
  first_name: string | null;
  total: number;
  company: string;
  stage: 'cancelled' | 'delivered' | 'shipped' | 'picked_up' | 'printing' | 'queued' | 'waiting' | 'packing' | 'ready';
  stage_label: string;
  stage_detail: string;
  progress: number | null;
  ready_at: string | null;
  ready_date: string | null;
  est_delivery_date: string | null;
  steps: { key: string; label: string; done: boolean; at: string | null }[];
  lines: { name: string; qty: number; backordered: number; est_available_date: string | null }[];
  checked_at: string;
}
