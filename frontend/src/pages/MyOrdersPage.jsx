import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import CancelOrderButton from '../components/CancelOrderButton';
import OrderStatusTrack from '../components/OrderStatusTrack';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { listMyOrders } from '../services/orderService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';
import { one, statusLabel } from '../utils/orders';

export default function MyOrdersPage() {
  const [orders, setOrders] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try {
      setOrders(await listMyOrders());
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, []);
  useEffect(() => {
    load();
    const t = setInterval(() => load(true), 30000); // keep the tracking fresh
    return () => clearInterval(t);
  }, [load]);

  if (state === 'loading') return <Loading label="Loading your orders…" />;
  if (state === 'error') return <ErrorMessage message={error} onRetry={load} />;
  if (orders.length === 0) return <EmptyState title="No orders yet"><Link to="/">Browse the menu</Link></EmptyState>;

  return (
    <section>
      <h1>My orders</h1>
      <ul className="cart-list">
        {orders.map((o) => {
          const pay = one(o.payments);
          return (
            <li key={o.id} className="order-card">
              <div className="order-head">
                <Link to={`/orders/${o.id}`}><strong>Order #{o.id}</strong></Link>
                <span className="muted small">{new Date(o.created_at).toLocaleString()}</span>
              </div>
              <OrderStatusTrack status={o.order_status} />
              <p className="muted small">
                {o.order_items.map((i) => `${i.quantity}× ${i.food_name}`).join(', ')}
              </p>
              <div className="order-head">
                <span>
                  <strong>{formatMoney(o.total_amount)}</strong>
                  {pay && <span className="muted small"> · {statusLabel(pay.payment_method)} ({statusLabel(pay.payment_status)})</span>}
                </span>
                <span className="inline-actions">
                  <Link className="btn btn-ghost btn-small" to={`/orders/${o.id}`}>Details</Link>
                  {o.order_status === 'pending' && <CancelOrderButton orderId={o.id} onDone={() => load(true)} />}
                </span>
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
