import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { adminListRestaurants, decideRestaurant } from '../services/restaurantAdminService';
import { friendlyDbError } from '../utils/errors';

const TABS = [['pending', 'Waiting'], ['active', 'Live'], ['suspended', 'Suspended'], ['rejected', 'Rejected']];
const NEEDS_REASON = { reject: 'Reject', suspend: 'Suspend' };

function Row({ r, onChanged }) {
  const [asking, setAsking] = useState(null); // 'reject' | 'suspend' while the reason box is open
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function decide(decision, why = null) {
    setBusy(true);
    setError('');
    try {
      await decideRestaurant(r.id, decision, why);
      setAsking(null);
      setReason('');
      await onChanged();
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className="order-card">
      <div className="order-head">
        <strong>{r.name}</strong>
        <span className="muted small">{new Date(r.created_at).toLocaleString()}</span>
      </div>
      <p className="small">{r.address} · {r.phone}</p>
      {r.description && <p className="small muted">{r.description}</p>}
      <p className="small">Applicant: {r.applicant ?? 'unknown'}</p>
      {r.status_reason && <p className="small">Reason: {r.status_reason}</p>}

      {!asking && (
        <div className="inline-actions">
          {r.status === 'pending' && (
            <>
              <button type="button" className="btn btn-small" disabled={busy} onClick={() => decide('approve')}>Approve</button>
              <button type="button" className="btn btn-small btn-ghost" disabled={busy} onClick={() => setAsking('reject')}>Reject</button>
            </>
          )}
          {r.status === 'active' && <button type="button" className="btn btn-small btn-ghost" disabled={busy} onClick={() => setAsking('suspend')}>Suspend</button>}
          {r.status === 'suspended' && <button type="button" className="btn btn-small" disabled={busy} onClick={() => decide('reinstate')}>Reinstate</button>}
        </div>
      )}
      {asking && (
        <form className="inline-actions" onSubmit={(e) => { e.preventDefault(); if (reason.trim()) decide(asking, reason.trim()); }}>
          <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder={`Reason to ${asking} (required)`} maxLength={500} aria-label={`Reason to ${asking}`} autoFocus />
          <button className="btn btn-small btn-danger" disabled={busy || !reason.trim()}>{busy ? 'Saving…' : NEEDS_REASON[asking]}</button>
          <button type="button" className="btn btn-small btn-ghost" disabled={busy} onClick={() => { setAsking(null); setReason(''); }}>Back</button>
        </form>
      )}
      {error && <p className="field-error" role="alert">{error}</p>}
    </li>
  );
}

export default function AdminRestaurantsPage() {
  const [tab, setTab] = useState('pending');
  const [rows, setRows] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try {
      setRows(await adminListRestaurants(tab));
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, [tab]);
  useEffect(() => { load(); }, [load]);

  return (
    <section>
      <AdminNav />
      <h1>Restaurants</h1>
      <div className="tabs" role="tablist" aria-label="Restaurant status">
        {TABS.map(([key, label]) => (
          <button key={key} type="button" role="tab" aria-selected={tab === key} className={`tab ${tab === key ? 'tab-on' : ''}`} onClick={() => setTab(key)}>{label}</button>
        ))}
      </div>
      {state === 'loading' && <Loading label="Loading restaurants…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && rows.length === 0 && <EmptyState title="Nothing here">No {TABS.find(([k]) => k === tab)[1].toLowerCase()} restaurants.</EmptyState>}
      {state === 'ready' && rows.length > 0 && (
        <ul className="cart-list">{rows.map((r) => <Row key={r.id} r={r} onChanged={() => load(true)} />)}</ul>
      )}
    </section>
  );
}
