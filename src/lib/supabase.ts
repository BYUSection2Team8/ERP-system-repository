import { createClient, type SupabaseClient } from '@supabase/supabase-js';

// Values are injected at build time from GitHub secrets (or a local .env).
// Only the public anon key belongs here; database rules (RLS) protect the data.
const rawUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.trim();
const anonKey = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim();

// Keep only "https://<project>.supabase.co" even if the secret was pasted with a
// path such as /rest/v1/ (a common copy-paste mix-up that breaks sign-in).
function toProjectUrl(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    return new URL(value).origin;
  } catch {
    return value;
  }
}

const url = toProjectUrl(rawUrl);

export const isSupabaseConfigured = Boolean(url && anonKey);

export const supabase: SupabaseClient | null = isSupabaseConfigured
  ? createClient(url!, anonKey!)
  : null;

/**
 * A throw-away client for creating someone else's login (staff "Users & access"):
 * it does not store the new session, so the staff member stays signed in as themselves.
 */
export function createSignupClient(): SupabaseClient | null {
  if (!isSupabaseConfigured) return null;
  return createClient(url!, anonKey!, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, storageKey: 'pp-signup-client' },
  });
}
