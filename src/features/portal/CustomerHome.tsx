import { Logo } from '../../app/Logo';
import { useAuth } from '../auth/AuthProvider';

// Placeholder until the customer portal is built (Phase 9).
export function CustomerHome() {
  const { session, signOut } = useAuth();
  return (
    <div className="login-screen">
      <div className="login-card">
        <div className="login-brand">
          <Logo size={44} />
          <div>
            <h1>Poulson Prints</h1>
            <p className="muted">Customer portal</p>
          </div>
        </div>
        <p>
          Signed in as <strong>{session?.user.email}</strong>. Shopping, pickup orders and order
          history will appear here soon.
        </p>
        <button className="btn" onClick={signOut}>
          Sign out
        </button>
      </div>
    </div>
  );
}
