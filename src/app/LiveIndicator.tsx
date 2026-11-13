import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { dateTime } from '../lib/format';

/**
 * "Live" badge: shows that this browser is connected to Supabase Realtime and
 * when the last stock / order change arrived from any user (live_signals is
 * bumped by the database on every stock movement and order change).
 */
export function LiveIndicator() {
  const [status, setStatus] = useState<'connecting' | 'on' | 'off'>('connecting');
  const [last, setLast] = useState<string | null>(null);

  useEffect(() => {
    const client = supabase;
    if (!client) {
      setStatus('off');
      return;
    }
    void client.from('live_signals').select('changed_at').eq('topic', 'stock').maybeSingle()
      .then(({ data }) => data && setLast(data.changed_at as string));
    const channel = client
      .channel(`live-indicator:${Math.random().toString(36).slice(2)}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'live_signals' }, (payload) => {
        const row = payload.new as { changed_at?: string };
        if (row?.changed_at) setLast(row.changed_at);
      })
      .subscribe((s) => setStatus(s === 'SUBSCRIBED' ? 'on' : s === 'CLOSED' || s === 'CHANNEL_ERROR' || s === 'TIMED_OUT' ? 'off' : 'connecting'));
    return () => {
      void client.removeChannel(channel);
    };
  }, []);

  const title =
    status === 'on'
      ? `Connected: screens update by themselves when anyone makes a change.${last ? ` Last change ${dateTime(last)}.` : ''}`
      : status === 'off'
        ? 'Live updates are disconnected. Refresh the page to reconnect.'
        : 'Connecting to live updates…';
  return (
    <span className={`live ${status}`} title={title}>
      <span className="live-dot" aria-hidden="true" />
      {status === 'on' ? 'Live' : status === 'off' ? 'Offline' : 'Connecting'}
    </span>
  );
}
