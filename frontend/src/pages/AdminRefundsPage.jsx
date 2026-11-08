import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { listOnlinePayments } from '../services/adminService';
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
      <p className="small">{cust ? `${cust.first_name} ${cust.last_name}` : 'Customer'} · order {statusLabel(order?.order_status)} · paid {p.paid_at ? new Date(p.paid_at).toLocaleString() : '—'}</p>
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

export default function AdminRefundsPage() {
  const [rows, setRows] = useState([]); const [state, setState] = useState('loading'); const [error, setError] = useState('');
  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try { setRows(await listOnlinePayments()); setState('ready'); }
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
      {state === 'ready' && rows.length === 0 && <EmptyState title="No online payments yet" />}
      {state === 'ready' && rows.length > 0 && <ul className="cart-list">{rows.map((p) => <Row key={p.id} p={p} onChanged={() => load(true)} />)}</ul>}
    </section>
  );
}
