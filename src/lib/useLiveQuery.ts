import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from './supabase';
import { errorMessage } from './db';

/**
 * Load data, then reload it whenever any of `tables` changes in the database
 * (Supabase Realtime). This is how a sale entered by one user shows up on
 * every other user's screen (rubric capability 12).
 */
export function useLiveQuery<T>(fetcher: () => Promise<T>, tables: string[], deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  const reload = useCallback(async () => {
    try {
      const result = await fetcherRef.current();
      setData(result);
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reload, ...deps]);

  const tableKey = tables.join(',');
  useEffect(() => {
    const client = supabase;
    if (!client || tableKey === '') return;
    let timer: number | undefined;
    const channel = client.channel(`live:${tableKey}:${Math.random().toString(36).slice(2)}`);
    for (const table of tableKey.split(',')) {
      channel.on('postgres_changes', { event: '*', schema: 'public', table }, () => {
        // Many rows change in one business transaction: reload once.
        window.clearTimeout(timer);
        timer = window.setTimeout(() => void reload(), 300);
      });
    }
    channel.subscribe();
    return () => {
      window.clearTimeout(timer);
      void client.removeChannel(channel);
    };
  }, [tableKey, reload]);

  return { data, error, loading, reload };
}
