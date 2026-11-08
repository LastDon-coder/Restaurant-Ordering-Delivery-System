import { Link, NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';

export default function Layout() {
  const { user, profile, loading, signOut } = useAuth();

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
