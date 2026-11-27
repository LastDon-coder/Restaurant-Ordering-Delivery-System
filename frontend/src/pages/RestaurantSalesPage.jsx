import { Navigate, useOutletContext } from 'react-router-dom';
import ReportView from '../components/ReportView';

// The owner's / manager's view of their own restaurant's money. The server refuses anyone else.
export default function RestaurantSalesPage() {
  const { restaurant, canManage } = useOutletContext();
  if (!canManage) return <Navigate to="/restaurant" replace />;
  return (
    <section>
      <h2>Sales</h2>
      <p className="muted small">
        The platform keeps {Number(restaurant.commission_percent ?? 10)}% of the food and {Number(restaurant.delivery_commission_percent ?? 10)}% of the delivery fee. Orders count when an online payment is confirmed or a cash order is delivered.
      </p>
      <ReportView key={restaurant.id} restaurantId={restaurant.id} />
    </section>
  );
}
