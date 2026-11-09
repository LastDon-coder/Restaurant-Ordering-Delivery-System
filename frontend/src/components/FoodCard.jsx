import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { useCart } from '../context/CartContext';
import { formatMoney } from '../utils/format';
import FoodReviews from './FoodReviews';
import { Stars } from './Stars';

export default function FoodCard({ food, rating }) {
  const { user, role, loading: authLoading } = useAuth();
  const { addItem } = useCart();
  const [status, setStatus] = useState('idle'); // idle | adding | added
  const [error, setError] = useState('');
  const [showReviews, setShowReviews] = useState(false);

  // Reset the "Added" tick after a moment.
  useEffect(() => {
    if (status !== 'added') return undefined;
    const t = setTimeout(() => setStatus('idle'), 1500);
    return () => clearTimeout(t);
  }, [status]);

  async function onAdd() {
    setError('');
    setStatus('adding');
    const result = await addItem(food.id, 1);
    if (result.ok) setStatus('added');
    else {
      setStatus('idle');
      setError(result.error);
    }
  }

  let action = null;
  if (!authLoading && !user) {
    action = (
      <Link className="btn btn-small" to="/login" state={{ from: '/' }}>
        Log in to order
      </Link>
    );
  } else if (role === 'customer') {
    action = (
      <button type="button" className="btn btn-small" onClick={onAdd} disabled={status === 'adding'}>
        {status === 'adding' ? 'Adding…' : status === 'added' ? 'Added ✓' : 'Add to cart'}
      </button>
    );
  } // staff, admin and riders do not order, so they see no button

  return (
    <article className="card">
      {food.image_url ? (
        <img className="card-img" src={food.image_url} alt={food.food_name} loading="lazy" />
      ) : (
        <div className="card-img card-img-placeholder" aria-hidden="true">
          🍽️
        </div>
      )}
      <div className="card-body">
        <h3>{food.food_name}</h3>
        {food.description && <p className="muted">{food.description}</p>}
        {rating?.count > 0 && (
          <p className="rating-line">
            <Stars value={rating.avg} label={`${rating.avg} out of 5 stars from ${rating.count} reviews`} />
            <strong>{rating.avg.toFixed(1)}</strong>
            <button type="button" className="text-link" aria-expanded={showReviews} onClick={() => setShowReviews((s) => !s)}>
              {rating.count} review{rating.count > 1 ? 's' : ''} {showReviews ? '(hide)' : ''}
            </button>
          </p>
        )}
        {showReviews && <FoodReviews foodId={food.id} />}
        <div className="card-footer">
          <p className="price">{formatMoney(food.price)}</p>
          {action}
        </div>
        {error && (
          <p className="field-error" role="alert">
            {error}
          </p>
        )}
      </div>
    </article>
  );
}
