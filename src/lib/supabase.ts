import { createClient, type SupabaseClient } from '@supabase/supabase-js';

// Values are injected at build time from GitHub secrets (or a local .env).
// Only the public anon keys belong here; database rules (RLS) protect the data.
//
// Two Supabase projects: database 1 = Practice (rehearse freely), database 2 =
// Demo (kept clean for the presentation). Each device picks one on the sign-in
// page; the choice is remembered in this browser. A link can force one with
// ?db=practice or ?db=demo (tracking links carry it, so a QR code scanned on a
// phone opens the order in the right database).

export type DbChoice = 'practice' | 'demo';

// Keep only "https://<project>.supabase.co" even if the secret was pasted with a
// path such as /rest/v1/ (a common copy-paste mix-up that breaks sign-in).
function toProjectUrl(value: string | undefined): string | undefined {
  const v = value?.trim();
  if (!v) return undefined;
  try {
    return new URL(v).origin;
  } catch {
    return v;
  }
}

const configs: Record<DbChoice, { url?: string; key?: string; label: string; short: string }> = {
  practice: {
    url: toProjectUrl(import.meta.env.VITE_SUPABASE_URL as string | undefined),
    key: (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim(),
    label: 'Practice (database 1)',
    short: 'Practice DB',
  },
  demo: {
    url: toProjectUrl(import.meta.env.VITE_SUPABASE_DEMO_URL as string | undefined),
    key: (import.meta.env.VITE_SUPABASE_DEMO_ANON_KEY as string | undefined)?.trim(),
    label: 'Demo (database 2)',
    short: 'Demo DB',
  },
};

const STORAGE_KEY = 'pp-database';
const configured = (c: DbChoice) => Boolean(configs[c].url && configs[c].key);

/** ?db=… in the page URL or inside the hash route (#/track/abc?db=demo). */
function urlChoice(): DbChoice | null {
  if (typeof window === 'undefined') return null;
  const fromSearch = new URLSearchParams(window.location.search).get('db');
  const hashQuery = window.location.hash.split('?')[1] ?? '';
  const v = fromSearch ?? new URLSearchParams(hashQuery).get('db');
  return v === 'practice' || v === 'demo' ? v : null;
}

function storedChoice(): DbChoice | null {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v === 'practice' || v === 'demo' ? v : null;
  } catch {
    return null;
  }
}

function pickChoice(): DbChoice {
  const wanted = urlChoice() ?? storedChoice() ?? 'practice';
  if (configured(wanted)) return wanted;
  return configured('practice') ? 'practice' : configured('demo') ? 'demo' : wanted;
}

export const dbChoice: DbChoice = pickChoice();
export const dbLabel = configs[dbChoice].label;
export const dbShortLabel = configs[dbChoice].short;
/** Both databases are set up, so the switch is worth showing. */
export const hasDatabaseChoice = configured('practice') && configured('demo');
export const databaseOptions = (['practice', 'demo'] as DbChoice[])
  .filter(configured)
  .map((c) => ({ value: c, label: configs[c].label }));

/** Remember the choice in this browser and reload on the other database. */
export function switchDatabase(choice: DbChoice) {
  try {
    localStorage.setItem(STORAGE_KEY, choice);
  } catch {
    /* storage blocked: the URL parameter below still selects it for this visit */
  }
  const url = new URL(window.location.href);
  url.searchParams.set('db', choice);
  const [route, query] = url.hash.split('?');
  if (query !== undefined) {
    const q = new URLSearchParams(query);
    q.delete('db');
    url.hash = q.toString() ? `${route}?${q}` : route;
  }
  window.location.replace(url.toString());
}

const url = configs[dbChoice].url;
const anonKey = configs[dbChoice].key;

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
