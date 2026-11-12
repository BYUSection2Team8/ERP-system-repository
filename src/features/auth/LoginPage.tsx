import { useState, type FormEvent } from 'react';
import { useAuth } from './AuthProvider';
import { isSupabaseConfigured } from '../../lib/supabase';
import { Logo } from '../../app/Logo';

export function LoginPage() {
  const { signIn } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const message = await signIn(email.trim(), password);
    if (message) setError(message);
    setBusy(false);
  }

  return (
    <div className="login-screen">
      <form className="login-card" onSubmit={handleSubmit}>
        <div className="login-brand">
          <Logo size={44} />
          <div>
            <h1>Poulson Prints</h1>
            <p className="muted">ERP sign in</p>
          </div>
        </div>

        {!isSupabaseConfigured && (
          <div className="notice warn">
            The database isn't connected yet. Add the <code>VITE_SUPABASE_URL</code> and{' '}
            <code>VITE_SUPABASE_ANON_KEY</code> repository secrets on GitHub, then re-run the deploy.
          </div>
        )}

        <label>
          Email
          <input
            type="email"
            autoComplete="username"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </label>
        <label>
          Password
          <input
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </label>

        {error && <div className="notice error">{error}</div>}

        <button type="submit" className="btn primary" disabled={busy || !isSupabaseConfigured}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </div>
  );
}
