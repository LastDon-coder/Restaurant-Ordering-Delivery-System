import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import { Stars } from '../components/Stars';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { useAuth } from '../context/AuthContext';
import { adminListFoodReviews, listOrderRatings, moderateReview } from '../services/reviewService';
import { friendlyDbError } from '../utils/errors';

const TABS = [['pending', 'To approve'], ['approved', 'Published'], ['hidden', 'Hidden']];
const who = (a) => (a ? `${a.first_name} ${a.last_name}` : 'Customer');
const when = (d) => new Date(d).toLocaleString();

function FoodReviewModeration() {
  const [tab, setTab] = useState('pending');
  const [rows, setRows] = useState([]);
  const [state, setState] = useState('loading');
  const [notice, setNotice] = useState('');
  const [busyId, setBusyId] = useState(null);

  const load = useCallback(async (status) => {
    setState('loading');
    try { setRows(await adminListFoodReviews(status)); setState('ready'); }
    catch (e) { console.error(e); setNotice(friendlyDbError(e)); setState('error'); }
  }, []);
  useEffect(() => { load(tab); }, [tab, load]);

  async function act(id, status) {
    setNotice(''); setBusyId(id);
    try { await moderateReview(id, status); await load(tab); }
    catch (e) { console.error(e); setNotice(friendlyDbError(e)); }
    finally { setBusyId(null); }
  }

  return (
    <div>
      <h2>Food reviews</h2>
      <div className="chips" role="tablist" aria-label="Review status">
        {TABS.map(([key, label]) => (
          <button key={key} type="button" role="tab" aria-selected={tab === key} className={`chip ${tab === key ? 'chip-active' : ''}`} onClick={() => setTab(key)}>{label}</button>
        ))}
      </div>
      {notice && <p className="form-error" role="alert">{notice}</p>}
      {state === 'loading' && <Loading label="Loading reviews…" />}
      {state === 'error' && <ErrorMessage message={notice || 'Could not load reviews.'} onRetry={() => load(tab)} />}
      {state === 'ready' && rows.length === 0 && <EmptyState title={tab === 'pending' ? 'Nothing waiting for approval' : 'No reviews here'} />}
      {state === 'ready' && rows.length > 0 && (
        <ul className="cart-list">
          {rows.map((r) => (
            <li key={r.id} className="order-card">
              <div className="order-head"><strong>{r.food?.food_name ?? 'Food'}</strong><Stars value={r.rating} /></div>
              {r.comment ? <p>{r.comment}</p> : <p className="muted small">No comment.</p>}
              <p className="muted small">{who(r.author)} · {when(r.created_at)}</p>
              <div className="inline-actions">
                {r.status !== 'approved' && <button type="button" className="btn btn-small" disabled={busyId === r.id} onClick={() => act(r.id, 'approved')}>Approve</button>}
                {r.status !== 'hidden' && <button type="button" className="btn btn-ghost btn-small" disabled={busyId === r.id} onClick={() => act(r.id, 'hidden')}>Hide</button>}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function OrderRatings() {
  const [rows, setRows] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');
  const load = useCallback(async () => {
    setState('loading');
    try { setRows(await listOrderRatings()); setState('ready'); }
    catch (e) { console.error(e); setError(friendlyDbError(e)); setState('error'); }
  }, []);
  useEffect(() => { load(); }, [load]);

  const avg = rows.length ? rows.reduce((s, r) => s + r.rating, 0) / rows.length : 0;
  const del = rows.filter((r) => r.delivery_rating);
  const avgDel = del.length ? del.reduce((s, r) => s + r.delivery_rating, 0) / del.length : 0;

  return (
    <div>
      <h2>Order and delivery ratings</h2>
      <p className="muted small">Private: only staff and admins see these.</p>
      {state === 'loading' && <Loading label="Loading ratings…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && rows.length === 0 && <EmptyState title="No order ratings yet">Customers can rate an order once it is delivered.</EmptyState>}
      {state === 'ready' && rows.length > 0 && (
        <>
          <p className="small">
            Average (last {rows.length}): order <strong>{avg.toFixed(1)}</strong>/5
            {del.length > 0 && <> · delivery <strong>{avgDel.toFixed(1)}</strong>/5</>}
          </p>
          <ul className="cart-list">
            {rows.map((r) => (
              <li key={r.id} className="order-card">
                <div className="order-head"><strong>Order #{r.order_id}</strong><Stars value={r.rating} label={`Order ${r.rating} out of 5`} /></div>
                {r.delivery_rating && <p className="small">Delivery: <Stars value={r.delivery_rating} label={`Delivery ${r.delivery_rating} out of 5`} /></p>}
                {r.comment && <p>{r.comment}</p>}
                <p className="muted small">{who(r.author)} · {when(r.created_at)}</p>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}

// Staff and admins read order ratings; only admins moderate food reviews.
export default function ReviewsPage() {
  const { role } = useAuth();
  return (
    <section>
      {role === 'admin' && <AdminNav />}
      <h1>Reviews</h1>
      {role === 'admin' && <FoodReviewModeration />}
      <OrderRatings />
    </section>
  );
}
