import { Navigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';

// Old /staff/... addresses: restaurant staff are sent to their restaurant's dashboard; the platform admin keeps the all-restaurants view.
export default function StaffEntry({ to, children }) {
  const { role } = useAuth();
  return role === 'staff' ? <Navigate to={to} replace /> : children;
}
