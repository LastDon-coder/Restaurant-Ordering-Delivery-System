import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { listOnlinePayments } from '../services/adminService';
import { adminDismissRefundRequest, adminListRefundRequests } from '../services/refundRequestService';
import { refundPayment } from '../services/paymentService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';
import { one, statusLabel } from '../utils/orders';

function Row({ p, onChanged }) {
  const order = one(p.orders); const cust = one(order?.profiles);
  const [open, setOpen] = useState(false); const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  const refund = p.refund;
  const canRefund = p.payment_status === 'paid' && (!refund || refund.refund_status === 'failed');

  async function submit(e) {
    e.preventDefault(); if (!reason.trim()) return;
    setBusy(true); setError('');
    try { await refundPayment(p.order_id, reason.trim()); setOpen(false); setReason(''); await onChanged(); }
    catch (err) { console.error(err); setError(err.message || friendlyDbError(err)); }
    finally { setBusy(false); }
  }

  return (
    <li className="order-card">
      <div className="order-head"><strong>Order #{p.order_id}</strong><span>{formatMoney(p.amount)}</span></div>
      <p className="small">{one(order?.restaurants)?.name ?? 'Restaurant'} · {cust ? `${cust.first_name} ${cust.last_name}` : 'Customer'} · order {statusLabel(order?.order_status)} · paid {p.paid_at ? new Date(p.paid_at).toLocaleString() : '—'}</p>
      <p className="small">
        Payment: <span className={`pill ${p.payment_status === 'refunded' ? 'pill-wait' : 'pill-ok'}`}>{statusLabel(p.payment_status)}</span>
        {refund && <> Refund: <span className={`pill ${refund.refund_status === 'processed' ? 'pill-ok' : refund.refund_status === 'failed' ? 'pill-cancelled' : 'pill-wait'}`}>{statusLabel(refund.refund_status)}</span> <span className="muted">{refund.reason}</span></>}
      </p>
      {canRefund && !open && <div className="inline-actions"><button type="button" className="btn btn-small btn-ghost" onClick={() => setOpen(true)}>{refund?.refund_status === 'failed' ? 'Retry refund' : 'Refund'}</button></div>}
      {open && (
        <form className="inline-actions" onSubmit={submit}>
          <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason for refund (required)" maxLength={255} aria-label="Refund reason" autoFocus />
          <button className="btn btn-small btn-danger" disabled={busy || !reason.trim()}>{busy ? 'Refunding…' : `Refund ${formatMoney(p.amount)}`}</button>
          <button type="button" className="btn btn-small btn-ghost" onClick={() => setOpen(false)} disabled={busy}>Back</button>
        </form>
      )}
      {error && <p className="field-error" role="alert">{error}</p>}
    </li>
  );
}

function RequestRow({ q, onChanged }) {
  const [open, setOpen] = useState(false); const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  async function dismiss(e) {
    e.preventDefault(); if (!note.trim()) return;
    setBusy(true); setError('');
    try { await adminDismissRefundRequest(q.id, note.trim()); await onChanged(); }
    catch (err) { console.error(err); setError(friendlyDbError(err)); setBusy(false); }
  }
  return (
    <li className="order-card">
      <div className="order-head"><strong>Order #{q.order_id} · {q.restaurant}</strong><span>{formatMoney(q.amount)}</span></div>
      <p className="small">Requested by {q.requested_by ?? 'a team member'} · {new Date(q.created_at).toLocaleString()}</p>
      <p className="small">“{q.reason}”</p>
      <p className="muted small">To approve, use the Refund button on that order below. This request then closes by itself.</p>
      {!open && <div className="inline-actions"><button type="button" className="btn btn-small btn-ghost" onClick={() => setOpen(true)}>Dismiss request</button></div>}
      {open && (
        <form className="inline-actions" onSubmit={dismiss}>
          <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Note to the restaurant (required)" maxLength={255} aria-label="Dismissal note" autoFocus />
          <button className="btn btn-small btn-danger" disabled={busy || !note.trim()}>Dismiss</button>
          <button type="button" className="btn btn-small btn-ghost" onClick={() => setOpen(false)} disabled={busy}>Back</button>
        </form>
      )}
      {error && <p className="field-error" role="alert">{error}</p>}
    </li>
  );
}

export default function AdminRefundsPage() {
  const [requests, setRequests] = useState([]);
  const [rows, setRows] = useState([]); const [state, setState] = useState('loading'); const [error, setError] = useState('');
  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try { const [p, q] = await Promise.all([listOnlinePayments(), adminListRefundRequests('open')]); setRows(p); setRequests(q); setState('ready'); }
    catch (e) { console.error(e); setError(friendlyDbError(e)); setState('error'); }
  }, []);
  useEffect(() => { load(); }, [load]);
  return (
    <section>
      <AdminNav />
      <h1>Refunds</h1>
      <p className="muted small">Online (Paystack) payments. A refund returns the full amount to the customer's original payment method. Cash orders are not listed.</p>
      {state === 'loading' && <Loading label="Loading payments…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && requests.length > 0 && (
        <>
          <h2>Refund requests from restaurants ({requests.length})</h2>
          <ul className="cart-list">{requests.map((q) => <RequestRow key={q.id} q={q} onChanged={() => load(true)} />)}</ul>
          <h2>All online payments</h2>
        </>
      )}
      {state === 'ready' && rows.length === 0 && <EmptyState title="No online payments yet" />}
      {state === 'ready' && rows.length > 0 && <ul className="cart-list">{rows.map((p) => <Row key={p.id} p={p} onChanged={() => load(true)} />)}</ul>}
    </section>
  );
}
