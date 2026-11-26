import { Navigate, useOutletContext } from 'react-router-dom';
import { EmptyState } from '../components/StateMessage';
import { DeliveryManager } from './AdminDeliveryPage';
import { MenuManager } from './AdminMenuPage';

// Menu and delivery areas of the restaurant chosen in the dashboard (owners and managers only).
function Guard({ children }) {
  const { restaurant, canManage, live } = useOutletContext();
  if (!canManage) return <Navigate to="/restaurant" replace />;
  if (!live) return <EmptyState title="Not live yet">You can set up your menu once the restaurant is approved.</EmptyState>;
  return children(restaurant.id);
}

export const RestaurantMenuPage = () => <Guard>{(id) => <MenuManager restaurantId={id} />}</Guard>;
export const RestaurantDeliveryPage = () => <Guard>{(id) => <DeliveryManager restaurantId={id} />}</Guard>;
