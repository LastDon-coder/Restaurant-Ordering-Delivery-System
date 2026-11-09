import { NavLink } from 'react-router-dom';

export default function AdminNav() {
  return (
    <nav className="tabs" aria-label="Admin">
      <NavLink className="tab" to="/staff/orders">Orders</NavLink>
      <NavLink className="tab" to="/admin/menu">Menu</NavLink>
      <NavLink className="tab" to="/admin/delivery">Delivery</NavLink>
      <NavLink className="tab" to="/staff/reviews">Reviews</NavLink>
      <NavLink className="tab" to="/admin/refunds">Refunds</NavLink>
      <NavLink className="tab" to="/admin/users">Users</NavLink>
    </nav>
  );
}
