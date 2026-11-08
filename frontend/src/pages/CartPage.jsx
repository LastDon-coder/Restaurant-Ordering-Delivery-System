import { Link } from 'react-router-dom';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { useCart } from '../context/CartContext';
import { formatMoney } from '../utils/format';
import { useState } from 'react';

const MAX = 50;

export default function CartPage() {
  const { cart, loading, busy, loadError, refresh, setQuantity, removeItem } = useCart();
  const [error, setError] = useState('');

  async function change(action) {
    setError('');
    const result = await action();
    if (!result.ok) setError(result.error);
  }

  if (loading && cart.items.length === 0) return <Loading label="Loading your cart…" />;
  if (loadError) return <ErrorMessage message={loadError} onRetry={refresh} />;
  if (cart.items.length === 0) {
    return (
      <EmptyState title="Your cart is empty">
        <Link to="/">Browse the menu</Link>
      </EmptyState>
    );
  }

  const { summary } = cart;
  const unavailable = cart.items.filter((i) => !i.is_available);

  return (
    <section>
      <h1>Your cart</h1>
      {unavailable.length > 0 && (
        <p className="form-error" role="alert">
          {unavailable.map((i) => i.food_name).join(', ')} {unavailable.length > 1 ? 'are' : 'is'} no longer available. Remove{' '}
          {unavailable.length > 1 ? 'them' : 'it'} to continue.
        </p>
      )}
      {error && (
        <p className="form-error" role="alert">
          {error}
        </p>
      )}

      <ul className="cart-list" aria-busy={busy}>
        {cart.items.map((item) => (
          <li key={item.id} className={`cart-line ${item.is_available ? '' : 'cart-line-off'}`}>
            <div className="cart-info">
              <h3>{item.food_name}</h3>
              <p className="muted">
                {formatMoney(item.price)} each{!item.is_available && ' · unavailable'}
              </p>
            </div>
            <div className="stepper" role="group" aria-label={`Quantity of ${item.food_name}`}>
              <button
                type="button"
                className="btn btn-ghost btn-small"
                aria-label="Decrease quantity"
                disabled={busy || item.quantity <= 1}
                onClick={() => change(() => setQuantity(item.id, item.quantity - 1))}
              >
                −
              </button>
              <span className="qty" aria-live="polite">
                {item.quantity}
              </span>
              <button
                type="button"
                className="btn btn-ghost btn-small"
                aria-label="Increase quantity"
                disabled={busy || item.quantity >= MAX || !item.is_available}
                onClick={() => change(() => setQuantity(item.id, item.quantity + 1))}
              >
                +
              </button>
            </div>
            <p className="line-total">{formatMoney(item.line_total)}</p>
            <button
              type="button"
              className="link-button"
              disabled={busy}
              onClick={() => change(() => removeItem(item.id))}
              aria-label={`Remove ${item.food_name}`}
            >
              Remove
            </button>
          </li>
        ))}
      </ul>

      <dl className="summary">
        <div>
          <dt>Subtotal</dt>
          <dd>{formatMoney(summary.subtotal)}</dd>
        </div>
        <div>
          <dt>Delivery fee</dt>
          <dd>{formatMoney(summary.delivery_fee)}</dd>
        </div>
        <div className="summary-total">
          <dt>Total</dt>
          <dd>{formatMoney(summary.total)}</dd>
        </div>
      </dl>
      <p className="muted small">Prices are confirmed again when you place the order.</p>
      <button type="button" className="btn" disabled title="Checkout comes next">
        Checkout (coming next)
      </button>
    </section>
  );
}
