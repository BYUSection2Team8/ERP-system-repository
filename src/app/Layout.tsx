import { NavLink, Outlet } from 'react-router-dom';
import { routes, type AppRoute } from './routes';
import { Logo } from './Logo';
import { useAuth } from '../features/auth/AuthProvider';

const sectionOrder: AppRoute['section'][] = [
  'Overview',
  'Sales',
  'Operations',
  'Purchasing',
  'Finance',
  'System',
];

export function Layout() {
  const { session, signOut } = useAuth();

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="sidebar-brand">
          <Logo size={32} />
          <span>Poulson Prints</span>
        </div>
        <nav>
          {sectionOrder.map((section) => {
            const items = routes.filter((r) => r.section === section);
            if (items.length === 0) return null;
            return (
              <div key={section} className="nav-section">
                <div className="nav-heading">{section}</div>
                {items.map((r) => (
                  <NavLink key={r.path} to={r.path} end={r.path === '/'} className="nav-link">
                    {r.label}
                  </NavLink>
                ))}
              </div>
            );
          })}
        </nav>
      </aside>
      <div className="main">
        <header className="topbar">
          <span className="muted">{session?.user.email}</span>
          <button className="btn" onClick={signOut}>
            Sign out
          </button>
        </header>
        <main className="content">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
