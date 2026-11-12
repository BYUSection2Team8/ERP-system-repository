import { HashRouter, Route, Routes, Navigate } from 'react-router-dom';
import { AuthProvider, useAuth } from './features/auth/AuthProvider';
import { LoginPage } from './features/auth/LoginPage';
import { CustomerHome } from './features/portal/CustomerHome';
import { Layout } from './app/Layout';
import { routes } from './app/routes';

// HashRouter keeps page refreshes working on GitHub Pages (no server-side routing).
function AppRoutes() {
  const { session, loading, role } = useAuth();

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
