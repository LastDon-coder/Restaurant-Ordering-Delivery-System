import { useCallback, useEffect, useState } from 'react';
import { EmptyState, ErrorMessage, Loading } from './StateMessage';
import { adminListSettlements, connectBank, listBanks, resolveAccount, setSplitActive } from '../services/settlementService';
import { friendlyDbError } from '../utils/errors';

// Connect form for ONE restaurant: pick the bank, type the account number, check the account name Paystack returns, then connect.
// The account number lives only in this form's state and in the request; it is never stored or shown again.
function ConnectForm({ restaurant, onDone, onCancel }) {
  const [banks, setBanks] = useState(null);
  const [bankCode, setBankCode] = useState('');
  const [number, setNumber] = useState('');
  const [accountName, setAccountName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    let live = true;
    listBanks().then((b) => { if (live) setBanks(b); }).catch((e) => { if (live) setError(e.message); });
    return () => { live = false; };
  }, []);

  // Any change to the bank or number invalidates the name that was checked.
  const edit = (setter) => (e) => { setter(e.target.value); setAccountName(''); };
  const numberOk = /^[0-9]{10}$/.test(number);

  async function check() {
    setBusy(true);
    setError('');
    try {
      const r = await resolveAccount(bankCode, number);
      setAccountName(r.account_name);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  async function connect() {
    setBusy(true);
    setError('');
    try {
      await connectBank(restaurant.restaurant_id, bankCode, number);
      setNumber('');
      await onDone();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="payout-form" onSubmit={(e) => e.preventDefault()}>
      <strong>Connect a bank account for {restaurant.name}</strong>
      {banks === null && !error && <Loading label="Loading banks…" />}
      {banks && (
        <>
          <label className="small">Bank
            <select value={bankCode} onChange={edit(setBankCode)}>
              <option value="">Choose a bank…</option>
              {banks.map((b) => <option key={b.code} value={b.code}>{b.name}</option>)}
            </select>
          </label>
          <label className="small">Account number (10 digits)
            <input inputMode="numeric" autoComplete="off" maxLength={10} value={number} onChange={edit((v) => setNumber(v.replace(/\D/g, '')))} />
          </label>
          <button type="button" className="btn btn-small btn-ghost" disabled={busy || !bankCode || !numberOk} onClick={check}>{busy && !accountName ? 'Checking…' : 'Check name'}</button>
        </>
      )}
      {accountName && (
        <p className="small" style={{ flexBasis: '100%' }}>
          Account name: <strong>{accountName}</strong>. Connect only if this matches the restaurant.
        </p>
      )}
      <div className="inline-actions">
        <button type="button" className="btn btn-small" disabled={busy || !accountName} onClick={connect}>{busy && accountName ? 'Connecting…' : 'Connect'}</button>
        <button type="button" className="btn btn-small btn-ghost" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
      {error && <p className="field-error" role="alert" style={{ flexBasis: '100%' }}>{error}</p>}
    </form>
  );
}

// Admin: which restaurants are paid directly by Paystack (split payments) and which are not.
export default function SettlementSection() {
  const [rows, setRows] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');
  const [open, setOpen] = useState(null);
  const [busyId, setBusyId] = useState(null);
  const [actionError, setActionError] = useState('');

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try {
      setRows(await adminListSettlements());
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, []);
  useEffect(() => { load(); }, [load]);

  async function toggle(r) {
    setBusyId(r.restaurant_id);
    setActionError('');
    try {
      await setSplitActive(r.restaurant_id, !r.active);
      await load(true);
    } catch (e) {
      console.error(e);
      setActionError(friendlyDbError(e));
    } finally {
      setBusyId(null);
    }
  }

  const opened = rows.find((r) => r.restaurant_id === open);
  return (
    <div>
      <h2>Paystack split payments</h2>
      <p className="muted small">
        A restaurant with a connected bank account is paid its share directly by Paystack for online orders; the platform keeps its commission and the restaurant
        pays Paystack&apos;s fee. Other restaurants are paid through balances and payouts above. Changes apply to new payments only.
      </p>
      {state === 'loading' && <Loading label="Loading…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && rows.length === 0 && <EmptyState title="No restaurants yet">Approve an application first.</EmptyState>}
      {actionError && <p className="field-error" role="alert">{actionError}</p>}
      {state === 'ready' && rows.length > 0 && (
        <div className="table-wrap">
          <table className="report-table">
            <thead><tr><th>Restaurant</th><th>Bank account</th><th>Split</th><th /></tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.restaurant_id}>
                  <td>{r.name}</td>
                  <td>{r.connected ? `${r.bank_name} •••• ${r.account_last4} (${r.account_name})` : <span className="muted">Not connected</span>}</td>
                  <td>{!r.connected ? '—' : r.active ? 'On' : 'Off'}</td>
                  <td className="inline-actions">
                    <button type="button" className="btn btn-small btn-ghost" onClick={() => setOpen(open === r.restaurant_id ? null : r.restaurant_id)}>{r.connected ? 'Change account' : 'Connect'}</button>
                    {r.connected && (
                      <button type="button" className="btn btn-small btn-ghost" disabled={busyId === r.restaurant_id} onClick={() => toggle(r)}>{r.active ? 'Turn off' : 'Turn on'}</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {opened && <ConnectForm key={opened.restaurant_id} restaurant={opened} onCancel={() => setOpen(null)} onDone={async () => { setOpen(null); await load(true); }} />}
    </div>
  );
}
