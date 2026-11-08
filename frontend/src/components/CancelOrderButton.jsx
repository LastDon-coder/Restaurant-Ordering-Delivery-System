import { useState } from 'react';
import { cancelMyOrder } from '../services/orderService';
import { friendlyDbError } from '../utils/errors';

// Two-step (Cancel -> "Yes, cancel") so a stray tap doesn't cancel an order.
export default function CancelOrderButton({ orderId, onDone }) {
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function confirm() {
    setBusy(true);
    setError('');
    try {
      await cancelMyOrder(orderId);
      onDone();
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setBusy(false);
      setAsking(false);
    }
  }

  return (
    <span className="inline-actions">
      {!asking ? (
        <button type="button" className="btn btn-ghost btn-small" onClick={() => setAsking(true)}>Cancel order</button>
      ) : (
        <>
          <span>Cancel this order?</span>
          <button type="button" className="btn btn-small btn-danger" onClick={confirm} disabled={busy}>{busy ? 'Cancelling…' : 'Yes, cancel'}</button>
          <button type="button" className="btn btn-ghost btn-small" onClick={() => setAsking(false)} disabled={busy}>Keep it</button>
        </>
      )}
      {error && <span className="field-error" role="alert">{error}</span>}
    </span>
  );
}
