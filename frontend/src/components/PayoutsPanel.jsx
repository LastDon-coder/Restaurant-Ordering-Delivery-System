import { useCallback, useEffect, useState } from 'react';
import { getMyBalance, listPayouts, recordPayout, voidPayout } from '../services/reportService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';
import { ErrorMessage, Loading } from './StateMessage';

const METHODS = [['bank_transfer', 'Bank transfer'], ['cash', 'Cash'], ['other', 'Other']];
const methodLabel = (m) => METHODS.find(([k]) => k === m)?.[1] ?? m;

function Sentence({ name, outstanding }) {
  if (outstanding === 0) return <p><strong>All settled.</strong> Nothing is owed either way.</p>;
  return outstanding > 0
    ? <p>The platform owes <strong>{name}</strong> <strong>{formatMoney(outstanding)}</strong>.</p>
    : <p><strong>{name}</strong> owes the platform <strong>{formatMoney(-outstanding)}</strong>.</p>;
}

// Balance, payout history and (admin only) the form to record or void a payout for ONE restaurant.
// The direction is decided by who owes whom, so it cannot be chosen wrongly; the server also refuses payouts bigger than the balance.
export default function PayoutsPanel({ restaurantId, name, canRecord = false, onChange }) {
  const [bal, setBal] = useState(null);
  const [history, setHistory] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');
  const [form, setForm] = useState({ amount: '', method: 'bank_transfer', reference: '', note: '' });
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState('');
  const [voiding, setVoiding] = useState(null); // payout id whose reason box is open
  const [reason, setReason] = useState('');

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try {
      const [b, h] = await Promise.all([getMyBalance(restaurantId), listPayouts(restaurantId)]);
      setBal(b);
      setHistory(h);
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, [restaurantId]);
  useEffect(() => { load(); }, [load]);

  const outstanding = Number(bal?.outstanding ?? 0);
  const direction = outstanding > 0 ? 'to_restaurant' : 'to_platform';

  async function submit(e) {
    e.preventDefault();
    setFormError('');
    const amount = Number(form.amount);
    if (!(amount > 0) || Math.abs(Math.round(amount * 100) - amount * 100) > 1e-6) {
      setFormError('Enter an amount above 0 with at most 2 decimals.');
      return;
    }
    setBusy(true);
    try {
      await recordPayout({ restaurantId, direction, amount, method: form.method, reference: form.reference.trim(), note: form.note.trim() });
      setForm({ amount: '', method: 'bank_transfer', reference: '', note: '' });
      await load(true);
      onChange?.();
    } catch (err) {
      console.error(err);
      setFormError(friendlyDbError(err));
    } finally {
      setBusy(false);
    }
  }

  async function doVoid(id) {
    if (!reason.trim()) return;
    setBusy(true);
    setFormError('');
    try {
      await voidPayout(id, reason.trim());
      setVoiding(null);
      setReason('');
      await load(true);
      onChange?.();
    } catch (err) {
      console.error(err);
      setFormError(friendlyDbError(err));
    } finally {
      setBusy(false);
    }
  }

  if (state === 'loading') return <Loading label="Loading balance…" />;
  if (state === 'error') return <ErrorMessage message={error} onRetry={load} />;

  return (
    <div className="payouts">
      <Sentence name={name ?? 'This restaurant'} outstanding={outstanding} />
      <p className="muted small">
        Already paid to the restaurant {formatMoney(bal.paid_to_restaurant)} · paid to the platform {formatMoney(bal.paid_to_platform)}.
      </p>

      {canRecord && outstanding !== 0 && (
        <form className="payout-form" onSubmit={submit}>
          <strong className="small">{direction === 'to_restaurant' ? `Record a payment to ${name ?? 'the restaurant'}` : 'Record a payment received from the restaurant'}</strong>
          <label className="small">Amount (₦)
            <input type="number" inputMode="decimal" min="0.01" step="0.01" max={Math.abs(outstanding)} required value={form.amount}
              onChange={(e) => setForm({ ...form, amount: e.target.value })} />
          </label>
          <button type="button" className="btn btn-small btn-ghost" onClick={() => setForm({ ...form, amount: String(Math.abs(outstanding)) })}>Settle in full</button>
          <label className="small">How
            <select value={form.method} onChange={(e) => setForm({ ...form, method: e.target.value })}>
              {METHODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
            </select>
          </label>
          <label className="small">Bank reference{form.method === 'bank_transfer' ? ' (required)' : ''}
            <input value={form.reference} maxLength={100} required={form.method === 'bank_transfer'} onChange={(e) => setForm({ ...form, reference: e.target.value })} />
          </label>
          <label className="small">Note
            <input value={form.note} maxLength={255} onChange={(e) => setForm({ ...form, note: e.target.value })} />
          </label>
          <button className="btn btn-small" disabled={busy}>{busy ? 'Saving…' : 'Record payout'}</button>
        </form>
      )}
      {formError && <p className="field-error" role="alert">{formError}</p>}

      <h3>Payout history</h3>
      {history.length === 0 ? (
        <p className="muted small">No payouts recorded yet.</p>
      ) : (
        <ul className="cart-list">
          {history.map((p) => (
            <li key={p.id} className="order-card" style={p.voided_at ? { opacity: 0.6 } : undefined}>
              <div className="order-head">
                <strong>{formatMoney(p.amount)} {p.direction === 'to_restaurant' ? 'paid to the restaurant' : 'paid to the platform'}</strong>
                <span className="muted small">{new Date(p.created_at).toLocaleString()}</span>
              </div>
              <p className="small">{methodLabel(p.method)}{p.reference ? ` · ${p.reference}` : ''}{p.note ? ` · ${p.note}` : ''}</p>
              {p.voided_at && <p className="small"><strong>Voided</strong>: {p.void_reason}</p>}
              {canRecord && !p.voided_at && voiding !== p.id && (
                <button type="button" className="btn btn-small btn-ghost" onClick={() => { setVoiding(p.id); setReason(''); }}>Void</button>
              )}
              {canRecord && voiding === p.id && (
                <form className="inline-actions" onSubmit={(e) => { e.preventDefault(); doVoid(p.id); }}>
                  <input value={reason} maxLength={255} onChange={(e) => setReason(e.target.value)} placeholder="Reason to void (required)" aria-label="Reason to void" autoFocus />
                  <button className="btn btn-small btn-danger" disabled={busy || !reason.trim()}>Void payout</button>
                  <button type="button" className="btn btn-small btn-ghost" onClick={() => setVoiding(null)}>Back</button>
                </form>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
