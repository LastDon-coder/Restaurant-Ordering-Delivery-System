import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import FoodCard from '../components/FoodCard';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { useRestaurantMenu } from '../hooks/useRestaurantMenu';
import { getFoodRatings } from '../services/reviewService';
import { formatMoney } from '../utils/format';

export default function RestaurantPage() {
  const { slug } = useParams();
  const { restaurant, categories, foods, loading, error, notFound, reload } = useRestaurantMenu(slug);
  const [categoryId, setCategoryId] = useState(null); // null = all
  const [ratings, setRatings] = useState({});         // optional, failures ignored

  useEffect(() => {
    getFoodRatings().then(setRatings).catch((e) => console.error('ratings unavailable', e));
  }, []);
  useEffect(() => { setCategoryId(null); }, [slug]);

  const visible = useMemo(() => (categoryId ? foods.filter((f) => f.category_id === categoryId) : foods), [foods, categoryId]);

  if (loading) return <Loading label="Loading the menu…" />;
  if (notFound) {
    return (
      <EmptyState title="Restaurant not found">
        <Link to="/">See all restaurants</Link>
      </EmptyState>
    );
  }
  if (error) return <ErrorMessage message={error} onRetry={reload} />;

  return (
    <section>
      <p className="small"><Link to="/">← All restaurants</Link></p>
      <h1>{restaurant.name}</h1>
      {restaurant.description && <p className="muted">{restaurant.description}</p>}
      <p className="small">
        <span className={restaurant.is_open ? 'tag tag-open' : 'tag tag-closed'}>{restaurant.is_open ? 'Open' : 'Closed'}</span>{' '}
        <span className="muted">Delivery from {formatMoney(restaurant.base_delivery_fee)}</span>
      </p>
      {!restaurant.is_open && (
        <p className="form-error" role="status">This restaurant is closed right now, so you can look at the menu but not order.</p>
      )}

      {foods.length === 0 ? (
        <EmptyState title="The menu is empty">Nothing is available right now. Please check back soon.</EmptyState>
      ) : (
        <>
          <div className="chips" role="group" aria-label="Filter by category">
            <button type="button" className={`chip ${categoryId === null ? 'chip-active' : ''}`} onClick={() => setCategoryId(null)}>All</button>
            {categories.map((c) => (
              <button key={c.id} type="button" className={`chip ${categoryId === c.id ? 'chip-active' : ''}`} onClick={() => setCategoryId(c.id)}>
                {c.category_name}
              </button>
            ))}
          </div>
          {visible.length === 0 ? (
            <EmptyState title="Nothing in this category">Try another category.</EmptyState>
          ) : (
            <div className="grid">
              {visible.map((f) => (
                <FoodCard key={f.id} food={f} rating={ratings[f.id]} orderable={restaurant.is_open} from={`/r/${restaurant.slug}`} />
              ))}
            </div>
          )}
        </>
      )}
    </section>
  );
}
