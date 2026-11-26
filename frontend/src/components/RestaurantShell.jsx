import { NavLink, Outlet } from 'react-router-dom';
import { useRestaurant } from '../context/RestaurantContext';
import { EmptyState, ErrorMessage, Loading } from './StateMessage';

const STATUS_TEXT = {
  pending: 'Your application is waiting for review. Your team gets access once it is approved.',
  rejected: 'This application was not approved.',
  suspended: 'This restaurant is suspended and is not taking orders.',
};

// Wraps the restaurant pages: picks the restaurant, shows its status, and the tabs this role may use.
export default function RestaurantShell() {
  const { restaurants, current, state, reload, select } = useRestaurant();

  if (state === 'loading' || state === 'idle') return <Loading label="Loading your restaurant…" />;
  if (state === 'error') return <ErrorMessage message="Could not load your restaurant." onRetry={reload} />;
  if (!current) return <EmptyState title="You are not on a restaurant team">Ask an owner to add you, or apply to open your own restaurant.</EmptyState>;

  const canManage = current.member_role === 'owner' || current.member_role === 'manager';
  const live = current.status === 'active';
  return (
    <section>
      <div className="order-head">
        <h1>{current.name}</h1>
        {restaurants.length > 1 && (
          <label className="small">
            <span className="sr-only">Restaurant</span>
            <select value={current.id} onChange={(e) => select(Number(e.target.value))} aria-label="Restaurant">
              {restaurants.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
            </select>
          </label>
        )}
      </div>
      <p className="muted small">Your role: {current.member_role}</p>
      {!live && (
        <p className="form-error" role="status">
          {STATUS_TEXT[current.status]} {current.status_reason && `Reason: ${current.status_reason}`}
        </p>
      )}
      <nav className="tabs" aria-label="Restaurant">
        <NavLink className="tab" to="/staff/orders">Orders</NavLink>
        <NavLink className="tab" to="/restaurant" end>Settings</NavLink>
        {canManage && <NavLink className="tab" to="/restaurant/team">Team</NavLink>}
        <NavLink className="tab" to="/staff/reviews">Reviews</NavLink>
      </nav>
      <Outlet context={{ restaurant: current, canManage, live, reload }} />
    </section>
  );
}
