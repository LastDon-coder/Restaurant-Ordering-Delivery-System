import { useEffect, useState } from 'react';
import { listFoodReviews } from '../services/reviewService';
import { Stars } from './Stars';

// The approved reviews for one food, loaded when the customer opens them.
export default function FoodReviews({ foodId }) {
  const [state, setState] = useState('loading'); // loading | ready | error
  const [reviews, setReviews] = useState([]);

  function load() {
    setState('loading');
    listFoodReviews(foodId, 10)
      .then((r) => { setReviews(r); setState('ready'); })
      .catch((e) => { console.error(e); setState('error'); });
  }
  useEffect(load, [foodId]); // eslint-disable-line react-hooks/exhaustive-deps

  if (state === 'loading') return <p className="muted small" role="status">Loading reviews…</p>;
  if (state === 'error') return <p className="field-error" role="alert">Could not load reviews. <button type="button" className="text-link" onClick={load}>Try again</button></p>;
  if (reviews.length === 0) return <p className="muted small">No reviews yet.</p>;
  return (
    <ul className="review-list">
      {reviews.map((r, i) => (
        <li key={i}>
          <p><Stars value={r.rating} /> <span className="muted small">{r.reviewer} · {new Date(r.created_at).toLocaleDateString()}</span></p>
          {r.comment && <p className="small">{r.comment}</p>}
        </li>
      ))}
    </ul>
  );
}
