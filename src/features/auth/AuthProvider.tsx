import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../../lib/supabase';

// 'unknown' = signed in but no profile row (e.g. migrations not applied yet).
export type Role = 'staff' | 'customer' | 'unknown';

interface AuthState {
  session: Session | null;
  loading: boolean;
  role: Role | null; // null while loading
  fullName: string | null;
  signIn: (email: string, password: string) => Promise<string | null>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [role, setRole] = useState<Role | null>(null);
  const [fullName, setFullName] = useState<string | null>(null);

  useEffect(() => {
    if (!supabase) {
      setLoading(false);
      return;
    }
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  // Look up staff vs customer from the profiles table (set by the database).
  const userId = session?.user.id;
  useEffect(() => {
    if (!supabase || !userId) {
      setRole(null);
      setFullName(null);
      return;
    }
    let cancelled = false;
    supabase
      .from('profiles')
      .select('role, full_name')
      .eq('id', userId)
      .maybeSingle()
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error || !data) {
          setRole('unknown');
          return;
        }
        setRole(data.role === 'customer' ? 'customer' : 'staff');
        setFullName((data.full_name as string | null) ?? null);
      });
    return () => {
      cancelled = true;
    };
  }, [userId]);

  async function signIn(email: string, password: string): Promise<string | null> {
    if (!supabase) return 'The database is not connected yet.';
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    return error ? error.message : null;
  }

  async function signOut() {
    if (supabase) await supabase.auth.signOut();
  }

  return (
    <AuthContext.Provider value={{ session, loading, role, fullName, signIn, signOut }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside AuthProvider');
  return ctx;
}
