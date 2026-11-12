import { createClient, type SupabaseClient } from '@supabase/supabase-js';

// Values are injected at build time from GitHub secrets (or a local .env).
// Only the public anon key belongs here; database rules (RLS) protect the data.
const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const isSupabaseConfigured = Boolean(url && anonKey);

export const supabase: SupabaseClient | null = isSupabaseConfigured
  ? createClient(url!, anonKey!)
  : null;
