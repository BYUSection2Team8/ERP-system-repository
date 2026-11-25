import { useState, type FormEvent } from 'react';
import { useAuth } from './AuthProvider';
import { isSupabaseConfigured, supabase } from '../../lib/supabase';
import { Logo } from '../../app/Logo';
import { DatabaseSwitch } from '../../app/DatabaseSwitch';

// Sign in, or create a CUSTOMER account. Staff accounts are only made by staff
// (System -> Users & access): the site is public, so nobody can sign up as staff.
export function LoginPage() {
  const { signIn } = useAuth();
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [state, setState] = useState('UT');
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function handleSignIn(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const message = await signIn(email.trim(), password);
    if (message) setError(message);
    setBusy(false);
  }

  async function handleSignUp(e: FormEvent) {
    e.preventDefault();
    if (!supabase) return;
    if (password.length < 8) return setError('Use at least 8 characters for the password.');
    if (!/^[A-Za-z]{2}$/.test(state.trim())) return setError('Enter your 2-letter state (e.g. UT).');
    setBusy(true);
    setError(null);
    setInfo(null);
    try {
      const { data, error: err } = await supabase.auth.signUp({
        email: email.trim(),
        password,
        options: { data: { full_name: name.trim() } },
      });
      if (err) throw err;
      if (data.user && data.user.identities && data.user.identities.length === 0) {
        throw new Error('That email already has an account. Sign in instead.');
      }
      // The portal finishes the customer record on first load (see CustomerHome).
      try {
        localStorage.setItem('pp-pending-registration', JSON.stringify({ email: email.trim().toLowerCase(), name: name.trim(), state: state.trim().toUpperCase() }));
      } catch {
        /* storage blocked: the portal asks again */
      }
      if (!data.session) {
        setInfo('Account created. Check your email to confirm it, then sign in here. (You will finish your details in the portal.)');
        setMode('signin');
      }
    } catch (x) {
      const msg = x instanceof Error ? x.message : String(x);
      setError(/signups not allowed|disabled/i.test(msg) ? 'New accounts are switched off right now. Please ask Poulson Prints for a login.' : msg);
    } finally {
      setBusy(false);
    }
  }

  const signup = mode === 'signup';
  return (
    <div className="login-screen">
      <form className="login-card" onSubmit={signup ? handleSignUp : handleSignIn}>
        <div className="login-brand">
          <Logo size={44} />
          <div>
            <h1>Poulson Prints</h1>
            <p className="muted">{signup ? 'Create a customer account' : 'Sign in'}</p>
          </div>
        </div>

        <DatabaseSwitch />

        {!isSupabaseConfigured && (
          <div className="notice warn">
            The database isn't connected yet. Add the <code>VITE_SUPABASE_URL</code> and{' '}
            <code>VITE_SUPABASE_ANON_KEY</code> repository secrets on GitHub, then re-run the deploy.
          </div>
        )}

        {signup && (
          <label>
            Your name
            <input autoComplete="name" value={name} maxLength={80} onChange={(e) => setName(e.target.value)} required />
          </label>
        )}
        <label>
          Email
          <input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </label>
        <label>
          Password{signup && <span className="muted small"> (at least 8 characters)</span>}
          <input
            type="password"
            autoComplete={signup ? 'new-password' : 'current-password'}
            value={password}
            minLength={signup ? 8 : undefined}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </label>
        {signup && (
          <label>
            State
            <input className="state-input" maxLength={2} value={state} onChange={(e) => setState(e.target.value.toUpperCase())} required />
          </label>
        )}

        {error && <div className="notice error">{error}</div>}
        {info && <div className="notice ok">{info}</div>}

        <button type="submit" className="btn primary" disabled={busy || !isSupabaseConfigured}>
          {busy ? (signup ? 'Creating…' : 'Signing in…') : signup ? 'Create account' : 'Sign in'}
        </button>
        <button
          type="button"
          className="btn link"
          onClick={() => {
            setMode(signup ? 'signin' : 'signup');
            setError(null);
            setInfo(null);
          }}
        >
          {signup ? 'Already have an account? Sign in' : 'New customer? Create an account'}
        </button>
        {signup && <p className="muted small" style={{ margin: 0 }}>Staff accounts are created by Poulson Prints staff.</p>}
      </form>
    </div>
  );
}
