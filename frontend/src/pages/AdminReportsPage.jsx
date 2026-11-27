import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import PayoutsPanel from '../components/PayoutsPanel';
import ReportView from '../components/ReportView';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { getBalances, getByRestaurant, setCommission } from '../services/reportService';
import { downloadCsv, toCsv } from '../utils/csv';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';

const lagosDay = (offsetDays = 0) =>
  new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Lagos' }).format(new Date(Date.now() + offsetDays * 86400000));

const REST_COLUMNS = [
  ['name', 'Restaurant'], ['status', 'Status'], ['commission_percent', 'Food commission %'], ['delivery_commission_percent', 'Delivery commission %'],
  ['orders', 'Orders'], ['gross', 'Gross'], ['commission', 'Commission on food'], ['delivery_commission', 'Commission on delivery'],
  ['platform_income', 'Platform income'], ['restaurant_share', 'Restaurant share'], ['balance', 'Balance (+ platform owes restaurant)'],
];

// One restaurant's two commission rates. Both are sent together; the new rates apply to future orders only.
function RateRow({ r, onSaved }) {
  const [food, setFood] = useState(String(r.commission_percent));
  const [delivery, setDelivery] = useState(String(r.delivery_commission_percent));
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const dirty = Number(food) !== Number(r.commission_percent) || Number(delivery) !== Number(r.delivery_commission_percent);
  const valid = [food, delivery].every((v) => v !== '' && Number(v) >= 0 && Number(v) <= 100);

  async function save(e) {
    e.preventDefault();
    setBusy(true);
    setMsg('');
    try {
      await setCommission(r.restaurant_id, Number(food), Number(delivery));
      setMsg('Saved');
      await onSaved();
    } catch (err) {
      console.error(err);
      setMsg(friendlyDbError(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <tr>
      <td>{r.name}{r.status !== 'active' && <span className="muted small"> ({r.status})</span>}</td>
      <td>{r.orders}</td>
      <td>{formatMoney(r.gross)}</td>
      <td>{formatMoney(r.platform_income)}</td>
      <td>{formatMoney(r.restaurant_share)}</td>
      <td>{Number(r.balance) === 0 ? '—' : `${formatMoney(Math.abs(r.balance))} ${Number(r.balance) > 0 ? 'to pay restaurant' : 'to collect'}`}</td>
      <td>
        <form className="rate-form" onSubmit={save}>
          <label className="small">Food %<input type="number" inputMode="decimal" min="0" max="100" step="0.01" value={food} onChange={(e) => setFood(e.target.value)} aria-label={`Food commission for ${r.name}`} /></label>
          <label className="small">Delivery %<input type="number" inputMode="decimal" min="0" max="100" step="0.01" value={delivery} onChange={(e) => setDelivery(e.target.value)} aria-label={`Delivery commission for ${r.name}`} /></label>
          <button className="btn btn-small" disabled={busy || !dirty || !valid}>{busy ? 'Saving…' : 'Save'}</button>
          {msg && <span className="small" role="status">{msg}</span>}
        </form>
      </td>
    </tr>
  );
}

// Who owes whom right now (all time), and the payout panel for the restaurant you open.
function BalancesSection() {
  const [rows, setRows] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');
  const [open, setOpen] = useState(null);

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try {
      setRows(await getBalances());
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, []);
  useEffect(() => { load(); }, [load]);

  const opened = rows.find((r) => r.restaurant_id === open);
  return (
    <div>
      <h2>Balances and payouts</h2>
      <p className="muted small">All-time. Online orders: the platform holds the money and owes the restaurant its share. Cash orders: the restaurant holds the cash and owes the platform its commission.</p>
      {state === 'loading' && <Loading label="Loading balances…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && rows.length === 0 && <EmptyState title="No restaurants yet">Approve an application first.</EmptyState>}
      {state === 'ready' && rows.length > 0 && (
        <div className="table-wrap">
          <table className="report-table">
            <thead><tr><th>Restaurant</th><th>Outstanding</th><th>Paid to restaurant</th><th>Paid to platform</th><th /></tr></thead>
            <tbody>
              {rows.map((b) => {
                const o = Number(b.outstanding);
                return (
                  <tr key={b.restaurant_id}>
                    <td>{b.name}</td>
                    <td>{o === 0 ? 'Settled' : `${formatMoney(Math.abs(o))} ${o > 0 ? '(platform owes)' : '(restaurant owes)'}`}</td>
                    <td>{formatMoney(b.paid_to_restaurant)}</td>
                    <td>{formatMoney(b.paid_to_platform)}</td>
                    <td><button type="button" className="btn btn-small btn-ghost" onClick={() => setOpen(open === b.restaurant_id ? null : b.restaurant_id)}>{open === b.restaurant_id ? 'Close' : 'Payouts'}</button></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {opened && <PayoutsPanel key={opened.restaurant_id} restaurantId={opened.restaurant_id} name={opened.name} canRecord onChange={() => load(true)} />}
    </div>
  );
}

export default function AdminReportsPage() {
  const [from, setFrom] = useState(() => lagosDay(-29));
  const [to, setTo] = useState(() => lagosDay());
  const [rows, setRows] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try {
      setRows(await getByRestaurant(from, to));
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, [from, to]);
  useEffect(() => { load(); }, [load]);

  return (
    <section>
      <AdminNav />
      <h1>Money</h1>
      <h2>All restaurants</h2>
      <ReportView restaurantId={null} title="Platform sales by day" />

      <BalancesSection />

      <div className="order-head">
        <h2>By restaurant and commission rates</h2>
        {rows.length > 0 && (
          <button type="button" className="btn btn-small btn-ghost" onClick={() => downloadCsv(`sales-by-restaurant-${from}-to-${to}.csv`, toCsv(rows, REST_COLUMNS))}>Download CSV</button>
        )}
      </div>
      <p className="muted small">
        The period below is shown for the table. Changing a rate affects future orders only; past orders keep the rate they were recorded with.
      </p>
      <div className="report-filter">
        <label className="small">From <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="small">To <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>
      </div>
      {state === 'loading' && <Loading label="Loading restaurants…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && rows.length === 0 && <EmptyState title="No restaurants yet">Approve an application first.</EmptyState>}
      {state === 'ready' && rows.length > 0 && (
        <div className="table-wrap">
          <table className="report-table">
            <thead>
              <tr><th>Restaurant</th><th>Orders</th><th>Gross</th><th>Platform income</th><th>Restaurant share</th><th>Balance</th><th>Commission rates</th></tr>
            </thead>
            <tbody>{rows.map((r) => <RateRow key={r.restaurant_id} r={r} onSaved={() => load(true)} />)}</tbody>
          </table>
        </div>
      )}
    </section>
  );
}
