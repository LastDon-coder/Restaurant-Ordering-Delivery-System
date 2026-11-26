import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { Stars } from '../components/Stars';
import { listRestaurants } from '../services/restaurantService';
import { formatMoney } from '../utils/format';

export default function HomePage() {
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');          // debounced copy of search
  const [state, setState] = useState({ items: [], loading: true, error: null });
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const t = setTimeout(() => setQuery(search), 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let cancelled = false;
    setState((s) => ({ ...s, loading: true, error: null }));
    listRestaurants(query)
      .then((items) => { if (!cancelled) setState({ items, loading: false, error: null }); })
      .catch((e) => {
        console.error(e);
        if (!cancelled) setState({ items: [], loading: false, error: 'Could not load restaurants. Please try again.' });
      });
    return () => { cancelled = true; };
  }, [query, attempt]);

  return (
    <section>
      <h1>Order from a restaurant</h1>
      <label className="search">
        <span className="sr-only">Search restaurants</span>
        <input type="search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search restaurants by name" maxLength={60} />
      </label>

      {state.loading && state.items.length === 0 ? (
        <Loading label="Finding restaurants…" />
      ) : state.error ? (
        <ErrorMessage message={state.error} onRetry={() => setAttempt((n) => n + 1)} />
      ) : state.items.length === 0 ? (
        <EmptyState title={query ? 'No restaurant matches your search' : 'No restaurants yet'}>
          {query ? 'Try a different name.' : 'Please check back soon.'}
        </EmptyState>
      ) : (
        <div className="grid" aria-busy={state.loading}>
          {state.items.map((r) => (
            <Link key={r.id} to={`/r/${r.slug}`} className={`card restaurant-card ${r.is_open ? '' : 'restaurant-closed'}`}>
              {r.logo_url ? (
                <img className="card-img" src={r.logo_url} alt="" loading="lazy" />
              ) : (
                <div className="card-img card-img-placeholder" aria-hidden="true">🍲</div>
              )}
              <div className="card-body">
                <h3>{r.name}</h3>
                {r.description && <p className="muted">{r.description}</p>}
                {r.rating_count > 0 ? (
                  <p className="rating-line">
                    <Stars value={r.rating_avg} label={`${r.rating_avg} out of 5 stars from ${r.rating_count} reviews`} />
                    <strong>{r.rating_avg.toFixed(1)}</strong> <span className="muted">({r.rating_count})</span>
                  </p>
                ) : (
                  <p className="muted small">No reviews yet</p>
                )}
                <p className="small">
                  <span className={r.is_open ? 'tag tag-open' : 'tag tag-closed'}>{r.is_open ? 'Open' : 'Closed'}</span>{' '}
                  <span className="muted">Delivery from {formatMoney(r.base_delivery_fee)}</span>
                </p>
              </div>
            </Link>
          ))}
        </div>
      )}
    </section>
  );
}
