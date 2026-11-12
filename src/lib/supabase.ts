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
