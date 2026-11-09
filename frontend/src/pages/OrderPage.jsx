import { useCallback, useEffect, useState } from 'react';
import { Link, useLocation, useParams } from 'react-router-dom';
import CancelOrderButton from '../components/CancelOrderButton';
import OrderReviews from '../components/OrderReviews';
import OrderStatusTrack from '../components/OrderStatusTrack';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { getOrder } from '../services/orderService';
import { initializePayment } from '../services/paymentService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';

import { CLOSED, one, statusLabel as label } from '../utils/orders';

export default function OrderPage() {
  const { id } = useParams();
  const location = useLocation();
  const [order, setOrder] = useState(null);
  const [state, setState] = useState('loading'); // loading | ready | missing | error
  const [error, setError] = useState('');
  const [payError, setPayError] = useState(location.state?.payError || '');
  const [paying, setPaying] = useState(false);

  const load = useCallback(async () => {
    setState('loading');
    try {
      const data = await getOrder(Number(id));
      setOrder(data);
      setState(data ? 'ready' : 'missing');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, [id]);
  useEffect(() => { load(); }, [load]);

  async function payNow() {
    setPayError('');
    setPaying(true);
    try {
      const { authorization_url: url } = await initializePayment(order.id);
      window.location.assign(url);
    } catch (e) {
      setPayError(e.message);
      setPaying(false);
    }
  }

  if (state === 'loading') return <Loading label="Loading your order…" />;
  if (state === 'error') return <ErrorMessage message={error} onRetry={load} />;
  if (state === 'missing') return <EmptyState title="Order not found"><Link to="/">Back to the menu</Link></EmptyState>;

  const pay = one(order.payments); // one payment per order
  const closing = CLOSED.includes(order.order_status)
    ? [...(order.order_status_history ?? [])].filter((h) => h.to_status === order.order_status).sort((a, b) => b.created_at.localeCompare(a.created_at))[0]
    : null;
  const needsPayment = pay?.payment_method === 'online' && ['pending', 'failed'].includes(pay.payment_status) && order.order_status === 'pending';

  return (
    <section>
      <h1>Order #{order.id}</h1>
      <OrderStatusTrack status={order.order_status} />
      {closing?.reason && <p className="muted">Reason: {closing.reason}</p>}
      <p><strong>Payment:</strong> {pay ? `${label(pay.payment_method)} (${label(pay.payment_status)})` : '—'}</p>
      <p><Link to="/orders">← All my orders</Link></p>
      {order.order_status === 'pending' && <p><CancelOrderButton orderId={order.id} onDone={load} /></p>}
      {payError && <p className="form-error" role="alert">{payError}</p>}
      {needsPayment && (
        <button type="button" className="btn" onClick={payNow} disabled={paying}>{paying ? 'Opening payment…' : 'Pay now'}</button>
      )}
      <ul className="cart-list">
        {order.order_items.map((i) => (
          <li key={i.id} className="cart-line">
            <div className="cart-info"><h3>{i.food_name}</h3><p className="muted">{i.quantity} × {formatMoney(i.price)}</p></div>
            <p className="line-total">{formatMoney(i.subtotal)}</p>
          </li>
        ))}
      </ul>
      <dl className="summary">
        <div><dt>Subtotal</dt><dd>{formatMoney(order.subtotal)}</dd></div>
        <div><dt>Delivery fee{order.delivery_zone_name ? ` (${order.delivery_zone_name})` : ''}</dt><dd>{formatMoney(order.delivery_fee)}</dd></div>
        <div className="summary-total"><dt>Total</dt><dd>{formatMoney(order.total_amount)}</dd></div>
      </dl>
      <p className="muted">Deliver to: {order.delivery_street_address}, {order.delivery_city}, {order.delivery_state}{order.delivery_landmark ? ` (${order.delivery_landmark})` : ''}</p>
      {order.order_status === 'delivered' && <OrderReviews order={order} />}
    </section>
  );
}
