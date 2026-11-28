import { useEffect, useState } from 'react';
import { Navigate, useOutletContext } from 'react-router-dom';
import PayoutsPanel from '../components/PayoutsPanel';
import ReportView from '../components/ReportView';
import { getSettlement } from '../services/settlementService';

// The owner's / manager's view of their own restaurant's money. The server refuses anyone else.
export default function RestaurantSalesPage() {
  const { restaurant, canManage } = useOutletContext();
  const [bank, setBank] = useState(null); // { bank_name, account_last4, active } or null
  useEffect(() => {
    let live = true;
    setBank(null);
    if (canManage) getSettlement(restaurant.id).then((b) => { if (live) setBank(b); }).catch(() => {}); // a missing line is harmless
    return () => { live = false; };
  }, [restaurant.id, canManage]);
  if (!canManage) return <Navigate to="/restaurant" replace />;
  return (
    <section>
      <h2>Sales</h2>
      <p className="muted small">
        The platform keeps {Number(restaurant.commission_percent ?? 10)}% of the food and {Number(restaurant.delivery_commission_percent ?? 10)}% of the delivery fee. Orders count when an online payment is confirmed or a cash order is delivered.
      </p>
      {bank?.active && (
        <p className="small">Online payments are split: your share is paid straight to {bank.bank_name} •••• {bank.account_last4}; Paystack&apos;s fee comes out of it.</p>
      )}
      <ReportView key={restaurant.id} restaurantId={restaurant.id} />
      <h2>Balance and payouts</h2>
      <PayoutsPanel key={`p${restaurant.id}`} restaurantId={restaurant.id} name={restaurant.name} />
    </section>
  );
}
