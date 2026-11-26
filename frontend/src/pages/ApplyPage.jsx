import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { listMyApplications, submitApplication } from '../services/restaurantAdminService';
import { friendlyDbError } from '../utils/errors';

const LIMITS = { name: 100, description: 1000, phone: 30, address: 255 };
const LABEL = { pending: 'Waiting for review', active: 'Approved', rejected: 'Not approved', suspended: 'Suspended' };

export default function ApplyPage() {
  const [apps, setApps] = useState([]);
  const [state, setState] = useState('loading'); // loading | ready | error
  const [form, setForm] = useState({ name: '', description: '', phone: '', address: '' });
  const [errors, setErrors] = useState({});
  const [formError, setFormError] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setState('loading');
    try {
      setApps(await listMyApplications());
      setState('ready');
    } catch (e) {
      console.error(e);
      setState('error');
    }
  }, []);
  useEffect(() => { load(); }, [load]);

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));
  const hasPending = apps.some((a) => a.status === 'pending');

  function validate() {
    const next = {};
    if (form.name.trim().length < 2) next.name = 'At least 2 characters';
    if (!form.phone.trim()) next.phone = 'Required';
    if (!form.address.trim()) next.address = 'Required';
    for (const [k, max] of Object.entries(LIMITS)) if (form[k].length > max) next[k] = `Max ${max} characters`;
    setErrors(next);
    return Object.keys(next).length === 0;
  }

  async function onSubmit(e) {
    e.preventDefault();
    setFormError('');
    if (busy || !validate()) return;
    setBusy(true);
    try {
      await submitApplication(form);
      setForm({ name: '', description: '', phone: '', address: '' });
      await load();
    } catch (err) {
      console.error(err);
      setFormError(friendlyDbError(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="form-page">
      <h1>Open a restaurant</h1>
      <p className="muted">Apply to sell on the platform. We review every application, then email you. After approval your account becomes a restaurant account (it can no longer place customer orders).</p>

      {state === 'loading' && <Loading label="Loading your applications…" />}
      {state === 'error' && <ErrorMessage message="Could not load your applications." onRetry={load} />}

      {state === 'ready' && apps.length > 0 && (
        <>
          <h2>Your applications</h2>
          <ul className="cart-list">
            {apps.map((a) => (
              <li key={a.id} className="order-card">
                <div className="order-head">
                  <strong>{a.name}</strong>
                  <span className={`pill ${a.status === 'active' ? 'pill-ok' : a.status === 'pending' ? 'pill-wait' : 'pill-cancelled'}`}>{LABEL[a.status]}</span>
                </div>
                {a.status_reason && <p className="small">Reason: {a.status_reason}</p>}
                {a.status === 'active' && <p className="small"><Link to="/restaurant">Open your dashboard</Link> (you may need to log in again)</p>}
              </li>
            ))}
          </ul>
        </>
      )}

      {state === 'ready' && hasPending && (
        <EmptyState title="Your application is being reviewed">We will email you as soon as there is a decision.</EmptyState>
      )}

      {state === 'ready' && !hasPending && (
        <form onSubmit={onSubmit} className="form" noValidate>
          <h2>{apps.length ? 'Apply again' : 'Your restaurant'}</h2>
          {formError && <p className="form-error" role="alert">{formError}</p>}
          <label>
            Restaurant name
            <input value={form.name} onChange={set('name')} maxLength={LIMITS.name + 1} aria-invalid={!!errors.name} />
            {errors.name && <span className="field-error">{errors.name}</span>}
          </label>
          <label>
            About (optional)
            <textarea value={form.description} onChange={set('description')} rows={3} maxLength={LIMITS.description + 1} />
            {errors.description && <span className="field-error">{errors.description}</span>}
          </label>
          <label>
            Phone
            <input type="tel" value={form.phone} onChange={set('phone')} autoComplete="tel" maxLength={LIMITS.phone + 1} aria-invalid={!!errors.phone} />
            {errors.phone && <span className="field-error">{errors.phone}</span>}
          </label>
          <label>
            Address
            <input value={form.address} onChange={set('address')} maxLength={LIMITS.address + 1} aria-invalid={!!errors.address} />
            {errors.address && <span className="field-error">{errors.address}</span>}
          </label>
          <button className="btn" type="submit" disabled={busy}>{busy ? 'Sending…' : 'Send application'}</button>
        </form>
      )}
    </section>
  );
}
