import type { SupabaseClient } from '@supabase/supabase-js';
import { supabase } from './supabase';

// Thin helpers around the Supabase client so screens stay short.
// Business actions always go through Postgres functions (rpc), never direct
// inserts into stock or ledger tables (the database refuses those anyway).

export function db(): SupabaseClient {
  if (!supabase) throw new Error('The database is not connected yet.');
  return supabase;
}

interface QueryResult<T> {
  data: T | null;
  error: { message: string } | null;
}

/** Return the rows of a query or throw its error message. */
export function unwrap<T>(res: QueryResult<T>): T {
  if (res.error) throw new Error(res.error.message);
  return res.data as T;
}

/** Call a business function. Its error messages are written for end users. */
export async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const res = await db().rpc(fn, args);
  if (res.error) throw new Error(res.error.message);
  return res.data as T;
}

export function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
