import { HashRouter, Route, Routes, Navigate } from 'react-router-dom';
import { AuthProvider, useAuth } from './features/auth/AuthProvider';
import { LoginPage } from './features/auth/LoginPage';
import { Layout } from './app/Layout';
import { routes } from './app/routes';

// HashRouter keeps page refreshes working on GitHub Pages (no server-side routing).
function AppRoutes() {
  const { session, loading } = useAuth();

  if (loading) return <div className="center muted">Loading…</div>;
  if (!session) return <LoginPage />;

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
