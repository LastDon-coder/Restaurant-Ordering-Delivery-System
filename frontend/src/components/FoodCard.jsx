import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { useCart } from '../context/CartContext';
import { formatMoney } from '../utils/format';

export default function FoodCard({ food }) {
  const { user, role, loading: authLoading } = useAuth();
  const { addItem } = useCart();
  const [status, setStatus] = useState('idle'); // idle | adding | added
  const [error, setError] = useState('');

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
