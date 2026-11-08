import { Link, NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { useCart } from '../context/CartContext';

export default function Layout() {
  const { user, profile, role, loading, signOut } = useAuth();
  const { count } = useCart();

  return (
    <>
      <header className="site-header">
        <div className="container header-row">
          <Link to="/" className="brand">
            🍲 Restaurant
          </Link>
          <nav className="nav" aria-label="Main">
            <NavLink to="/" end>
              Menu
            </NavLink>
            {!loading && !user && (
              <>
                <NavLink to="/login">Log in</NavLink>
                <NavLink to="/register" className="btn btn-small">
                  Sign up
                </NavLink>
              </>
            )}
            {role === 'customer' && (
              <NavLink to="/cart" aria-label={`Cart, ${count} items`}>
                Cart{count > 0 && <span className="badge">{count}</span>}
              </NavLink>
            )}
            {user && (
              <>
                <span className="nav-user">Hi, {profile?.first_name ?? 'there'}</span>
                <button type="button" className="btn btn-ghost btn-small" onClick={signOut}>
                  Log out
                </button>
              </>
            )}
          </nav>
        </div>
      </header>
      <main className="container main">
        <Outlet />
      </main>
      <footer className="site-footer">
        <div className="container">© {new Date().getFullYear()} Restaurant</div>
      </footer>
    </>
  );
}
