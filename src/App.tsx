import { HashRouter, Route, Routes, Navigate, useLocation } from 'react-router-dom';
import { AuthProvider, useAuth } from './features/auth/AuthProvider';
import { LoginPage } from './features/auth/LoginPage';
import { CustomerHome } from './features/portal/CustomerHome';
import { TrackPage } from './features/tracking/TrackPage';
import { Layout } from './app/Layout';
import { routes } from './app/routes';

// HashRouter keeps page refreshes working on GitHub Pages (no server-side routing).
function AppRoutes() {
  const { session, loading, role } = useAuth();
  const location = useLocation();

  // Public order tracking link: no login needed (wow factor #1).
  if (location.pathname.startsWith('/track/')) {
    return (
      <Routes>
        <Route path="/track/:token" element={<TrackPage />} />
      </Routes>
    );
  }

  if (loading) return <div className="center muted">Loading…</div>;
  if (!session) return <LoginPage />;
  if (role === null) return <div className="center muted">Loading your account…</div>;
  if (role === 'customer') return <CustomerHome />;

  return (
    <Routes>
      <Route element={<Layout />}>
        {routes.map(({ path, component: Page }) => (
          <Route key={path} path={path} element={<Page />} />
        ))}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <HashRouter>
        <AppRoutes />
      </HashRouter>
    </AuthProvider>
  );
}
