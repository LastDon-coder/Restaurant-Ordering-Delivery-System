import { useCallback, useEffect, useState } from 'react';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { getMyDeliveries, updateDelivery } from '../services/riderService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';
import { statusLabel } from '../utils/orders';

function Job({ job, onChanged }) {
  const [failing, setFailing] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const a = job.address;
  const cod = job.payment_method === 'cash_on_delivery' && job.payment_status !== 'paid';
  const notReady = job.delivery_status === 'assigned' && job.order_status !== 'ready_for_delivery';

  async function go(status, why = null) {
    setBusy(true);
    setError('');
    try {
      await updateDelivery(job.order_id, status, why);
      await onChanged();
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setBusy(false);
    }
  }

  return (
    <li className="order-card">
      <div className="order-head">
        <strong>Order #{job.order_id}</strong>
        <span className={`pill ${job.delivery_status === 'picked_up' ? 'pill-ok' : 'pill-wait'}`}>{job.delivery_status === 'picked_up' ? 'On the way' : 'To pick up'}</span>
      </div>
      <p>{job.customer.name}{job.customer.phone && <> · <a href={`tel:${job.customer.phone}`}>{job.customer.phone}</a></>}</p>
      <p className="small">{a.street_address}, {a.city}, {a.state}{a.landmark ? ` (${a.landmark})` : ''}</p>
      <p className="small">Area: <strong>{job.zone_name ?? 'Other area'}</strong> · Delivery fee {formatMoney(job.delivery_fee)}</p>
      <p className="muted small">{job.items.map((i) => `${i.quantity}× ${i.food_name}`).join(', ')}</p>
      <p>{cod ? <strong>Collect {formatMoney(job.total_amount)} in cash</strong> : <span className="muted">Already paid ({formatMoney(job.total_amount)})</span>}</p>
      {notReady && <p className="muted small">Kitchen status: {statusLabel(job.order_status)}. You can pick up once it is Ready for delivery.</p>}

      {!failing && (
        <div className="inline-actions">
          {job.delivery_status === 'assigned' && (
            <button type="button" className="btn btn-small" disabled={busy || notReady} onClick={() => go('picked_up')}>Picked up</button>
          )}
          {job.delivery_status === 'picked_up' && (
            <>
              <button type="button" className="btn btn-small" disabled={busy} onClick={() => go('delivered')}>Delivered{cod ? ' (cash collected)' : ''}</button>
              <button type="button" className="btn btn-small btn-ghost" disabled={busy} onClick={() => setFailing(true)}>Could not deliver</button>
            </>
          )}
        </div>
      )}
      {failing && (
        <form className="inline-actions" onSubmit={(e) => { e.preventDefault(); if (reason.trim()) go('failed', reason.trim()); }}>
          <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Why could it not be delivered? (required)" maxLength={255} aria-label="Reason" autoFocus />
          <button className="btn btn-small btn-danger" type="submit" disabled={busy || !reason.trim()}>Confirm failed</button>
          <button className="btn btn-small btn-ghost" type="button" onClick={() => setFailing(false)} disabled={busy}>Back</button>
        </form>
      )}
      {error && <p className="field-error" role="alert">{error}</p>}
    </li>
  );
}

export default function RiderPage() {
  const [jobs, setJobs] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try {
      setJobs(await getMyDeliveries());
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, []);
  useEffect(() => {
    load();
    const t = setInterval(() => load(true), 20000);
    return () => clearInterval(t);
  }, [load]);

  return (
    <section>
      <div className="order-head">
        <h1>My deliveries</h1>
        <button type="button" className="btn btn-ghost btn-small" onClick={() => load()}>Refresh</button>
      </div>
      {state === 'loading' && <Loading label="Loading deliveries…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && jobs.length === 0 && <EmptyState title="No deliveries assigned to you right now">New jobs appear here automatically.</EmptyState>}
      {state === 'ready' && jobs.length > 0 && (
        <ul className="cart-list">{jobs.map((j) => <Job key={`${j.order_id}-${j.delivery_status}`} job={j} onChanged={() => load(true)} />)}</ul>
      )}
    </section>
  );
}
