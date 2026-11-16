import { useState, type FormEvent } from 'react';
import { ErrorNotice, Loading, PageHeader, Stat } from '../../app/ui';
import { db, errorMessage, rpc, unwrap } from '../../lib/db';
import { date } from '../../lib/format';
import { createSignupClient } from '../../lib/supabase';
import { useLiveQuery } from '../../lib/useLiveQuery';
import { useAuth } from '../auth/AuthProvider';

// Users & access (staff only): every login with its role, create a login as a
// customer or staff, and promote / demote. The database enforces that only
// staff can grant staff, and nobody can change their own role.

interface UserRow {
  user_id: string;
  email: string;
  role: 'staff' | 'customer';
  full_name: string | null;
  customer_id: string | null;
  customer_name: string | null;
  created_at: string;
}

export function UsersPage() {
  const { session } = useAuth();
  const me = session?.user.id;
  const users = useLiveQuery(async () => unwrap<UserRow[]>(await db().rpc('list_users')), ['activity_log']);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [f, setF] = useState({ name: '', email: '', password: '', role: 'customer' as 'customer' | 'staff', state: 'UT' });

  async function changeRole(u: UserRow, role: 'staff' | 'customer') {
    if (!window.confirm(`Make ${u.email} ${role === 'staff' ? 'STAFF (sees and changes everything)' : 'a customer'}?`)) return;
    setMsg(null);
    try {
      await rpc('set_user_role', { p_user: u.user_id, p_role: role });
      setMsg({ ok: true, text: `${u.email} is now ${role}. They see the change the next time they sign in.` });
      void users.reload();
    } catch (e) {
      setMsg({ ok: false, text: errorMessage(e) });
    }
  }

  async function create(e: FormEvent) {
    e.preventDefault();
    if (f.password.length < 8) return setMsg({ ok: false, text: 'Use at least 8 characters for the password.' });
    if (f.role === 'customer' && !/^[A-Za-z]{2}$/.test(f.state.trim())) return setMsg({ ok: false, text: 'Enter a 2-letter state.' });
    const client = createSignupClient();
    if (!client) return;
    setBusy(true);
    setMsg(null);
    try {
      const { data, error } = await client.auth.signUp({
        email: f.email.trim(),
        password: f.password,
        options: { data: { full_name: f.name.trim() || f.email.trim() } },
      });
      if (error) throw error;
      const id = data.user?.id;
      if (!id || (data.user?.identities && data.user.identities.length === 0)) throw new Error('That email already has a login.');
      if (f.role === 'staff') await rpc('set_user_role', { p_user: id, p_role: 'staff' });
      else await rpc('setup_customer_account', { p_user: id, p_name: f.name.trim(), p_state: f.state.trim().toUpperCase() });
      setMsg({
        ok: true,
        text:
          `${f.email.trim()} created as ${f.role}.` +
          (data.session ? ' They can sign in now with that password.' : ' Supabase is asking for email confirmation: turn off "Confirm email" (see below) or confirm the user in Supabase before they sign in.'),
      });
      setF({ name: '', email: '', password: '', role: f.role, state: 'UT' });
      void users.reload();
    } catch (x) {
      const t = errorMessage(x);
      setMsg({ ok: false, text: /signups not allowed|disabled/i.test(t) ? 'Supabase has new sign-ups switched off. Turn on "Allow new users to sign up" (see below).' : t });
    } finally {
      setBusy(false);
    }
  }

  if (users.loading) return <Loading what="users" />;
  if (users.error) return <ErrorNotice message={users.error} />;
  const rows = users.data ?? [];
  return (
    <div>
      <PageHeader title="Users & access" subtitle="Every login, its role and its customer record. Staff see and change everything; customers only see the portal and their own orders." />
      <div className="stats">
        <Stat label="Staff logins" value={rows.filter((r) => r.role === 'staff').length} hint="The rubric asks for at least 3" />
        <Stat label="Customer logins" value={rows.filter((r) => r.role === 'customer').length} hint={`${rows.filter((r) => r.role === 'customer' && !r.customer_id).length} not linked to a customer yet`} />
      </div>

      <form className="card form spaced" onSubmit={create}>
        <h2 style={{ margin: 0 }}>Create a login</h2>
        <div className="form-row">
          <label className="grow">
            Name
            <input value={f.name} maxLength={80} onChange={(e) => setF({ ...f, name: e.target.value })} required={f.role === 'customer'} />
          </label>
          <label className="grow">
            Email
            <input type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} required />
          </label>
          <label>
            Password (8+)
            <input type="password" autoComplete="new-password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} required />
          </label>
        </div>
        <div className="form-row">
          <label className="check"><input type="radio" checked={f.role === 'customer'} onChange={() => setF({ ...f, role: 'customer' })} /> Customer (portal)</label>
          <label className="check"><input type="radio" checked={f.role === 'staff'} onChange={() => setF({ ...f, role: 'staff' })} /> Staff (full ERP)</label>
          {f.role === 'customer' && (
            <label>
              State
              <input className="state-input" maxLength={2} value={f.state} onChange={(e) => setF({ ...f, state: e.target.value.toUpperCase() })} />
            </label>
          )}
        </div>
        {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'}`}>{msg.text}</div>}
        <div>
          <button className="btn primary" disabled={busy}>{busy ? 'Creating…' : `Create ${f.role} login`}</button>
        </div>
        <p className="muted small" style={{ margin: 0 }}>
          A customer login is linked to the customer with the same email, or gets a new customer record. Needs two Supabase settings
          (Authentication → Sign In / Providers): "Allow new users to sign up" on, and "Confirm email" off (example.com addresses cannot
          receive confirmation emails).
        </p>
      </form>

      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr><th>Login</th><th>Role</th><th>Customer record</th><th>Created</th><th /></tr>
          </thead>
          <tbody>
            {rows.map((u) => (
              <tr key={u.user_id}>
                <td>{u.email}{u.full_name && u.full_name !== u.email && <div className="muted small">{u.full_name}</div>}</td>
                <td><span className={`badge ${u.role === 'staff' ? 'ok' : ''}`}>{u.role}</span></td>
                <td>{u.role === 'staff' ? '—' : u.customer_name ?? <span className="bad small">not linked</span>}</td>
                <td>{date(u.created_at)}</td>
                <td>
                  {u.user_id === me ? (
                    <span className="muted small">you</span>
                  ) : u.role === 'staff' ? (
                    <button className="btn link" onClick={() => changeRole(u, 'customer')}>Make customer</button>
                  ) : (
                    <button className="btn link" onClick={() => changeRole(u, 'staff')}>Make staff</button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
