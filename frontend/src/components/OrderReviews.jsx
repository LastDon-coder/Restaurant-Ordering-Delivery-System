import { useCallback, useEffect, useState } from 'react';
import { getMyReviewsForOrder, submitFoodReview, submitOrderRating } from '../services/reviewService';
import { friendlyDbError } from '../utils/errors';
import { StarInput, Stars } from './Stars';

const STATUS_TEXT = { pending: 'Thanks! Waiting for approval before it appears on the menu.', approved: 'Published on the menu.', hidden: 'Not published.' };
const MAX = 500;

function ItemReview({ item, existing, onDone }) {
  const [open, setOpen] = useState(false);
  const [rating, setRating] = useState(0);
  const [comment, setComment] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  if (existing) {
    return (
      <p className="small"><Stars value={existing.rating} /> <span className="muted">{STATUS_TEXT[existing.status]}</span></p>
    );
  }
  if (!open) return <button type="button" className="btn btn-ghost btn-small" onClick={() => setOpen(true)}>Review this item</button>;

  async function submit(e) {
    e.preventDefault(); setError('');
    if (!rating) return setError('Choose 1 to 5 stars.');
    if (comment.length > MAX) return setError(`Keep it under ${MAX} characters.`);
    setBusy(true);
    try { await submitFoodReview(item.id, rating, comment.trim()); await onDone(); }
    catch (err) { console.error(err); setError(friendlyDbError(err)); setBusy(false); }
  }
  return (
    <form className="form" onSubmit={submit} noValidate>
      {error && <p className="form-error" role="alert">{error}</p>}
      <StarInput name={`Rating for ${item.food_name}`} value={rating} onChange={setRating} />
      <label>Comment (optional)<textarea rows={2} maxLength={MAX + 1} value={comment} onChange={(e) => setComment(e.target.value)} /></label>
      <p className="muted small">Reviews are checked by the restaurant before they appear on the menu. You can only post once.</p>
      <div className="inline-actions">
        <button className="btn btn-small" disabled={busy}>{busy ? 'Sending…' : 'Post review'}</button>
        <button type="button" className="btn btn-ghost btn-small" onClick={() => setOpen(false)} disabled={busy}>Cancel</button>
      </div>
    </form>
  );
}

function OrderRatingForm({ orderId, existing, onDone }) {
  const [rating, setRating] = useState(0);
  const [delivery, setDelivery] = useState(0);
  const [comment, setComment] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  if (existing) {
    return (
      <div>
        <p className="small">Your order: <Stars value={existing.rating} />{existing.delivery_rating ? <> · Delivery: <Stars value={existing.delivery_rating} /></> : null}</p>
        {existing.comment && <p className="muted small">“{existing.comment}”</p>}
        <p className="muted small">Thank you for your feedback.</p>
      </div>
    );
  }
  async function submit(e) {
    e.preventDefault(); setError('');
    if (!rating) return setError('Choose 1 to 5 stars for the order.');
    if (comment.length > MAX) return setError(`Keep it under ${MAX} characters.`);
    setBusy(true);
    try { await submitOrderRating(orderId, rating, delivery, comment.trim()); await onDone(); }
    catch (err) { console.error(err); setError(friendlyDbError(err)); setBusy(false); }
  }
  return (
    <form className="form order-card" onSubmit={submit} noValidate>
      <h3>How was your order?</h3>
      {error && <p className="form-error" role="alert">{error}</p>}
      <div><p className="small">Overall</p><StarInput name="Overall rating" value={rating} onChange={setRating} /></div>
      <div><p className="small">Delivery (optional)</p><StarInput name="Delivery rating" value={delivery} onChange={setDelivery} /></div>
      <label>Comment (optional)<textarea rows={2} maxLength={MAX + 1} value={comment} onChange={(e) => setComment(e.target.value)} /></label>
      <p className="muted small">Only the restaurant sees this. You can only rate an order once.</p>
      <button className="btn btn-small" disabled={busy}>{busy ? 'Sending…' : 'Send rating'}</button>
    </form>
  );
}

// Shown on a DELIVERED order: rate the order and review each item. The database re-checks everything.
export default function OrderReviews({ order }) {
  const [mine, setMine] = useState(null);
  const [state, setState] = useState('loading');
  const ids = order.order_items.map((i) => i.id);

  const load = useCallback(async () => {
    try { setMine(await getMyReviewsForOrder(order.id, ids)); setState('ready'); }
    catch (e) { console.error(e); setState('error'); }
  }, [order.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, [load]);

  if (state === 'loading') return <p className="muted small" role="status">Loading your reviews…</p>;
  if (state === 'error') return <p className="field-error" role="alert">Could not load your reviews. <button type="button" className="text-link" onClick={load}>Try again</button></p>;

  return (
    <div>
      <h2>Rate your order</h2>
      <OrderRatingForm orderId={order.id} existing={mine.order} onDone={load} />
      <h3>Review the food</h3>
      <ul className="cart-list">
        {order.order_items.map((i) => (
          <li key={i.id} className="order-card">
            <strong>{i.food_name}</strong>
            <ItemReview item={i} existing={mine.foods[i.id]} onDone={load} />
          </li>
        ))}
      </ul>
    </div>
  );
}
