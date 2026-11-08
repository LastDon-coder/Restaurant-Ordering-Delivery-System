import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { Loading } from './StateMessage';

// Wrap routes that need a login (and optionally specific roles):
//   <Route element={<ProtectedRoute roles={['admin']} />}> ... </Route>
// This only controls what the user SEES. The database still enforces the real permissions.
export default function ProtectedRoute({ roles }) {
  const { user, role, loading } = useAuth();
  const location = useLocation();

  if (loading) return <Loading label="Checking your session…" />;
  if (!user) return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  if (roles && !roles.includes(role)) {
    return (
      <div className="state state-error" role="alert">
        <h2>Not allowed</h2>
        <p>Your account does not have access to this page.</p>
      </div>
    );
  }
  return <Outlet />;
}
