import { useCallback, useEffect, useState } from 'react';
import { getSalesByDay, getSummary } from '../services/reportService';
import { downloadCsv, toCsv } from '../utils/csv';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';
import { EmptyState, ErrorMessage, Loading } from './StateMessage';

// Dates are Nigerian days (the database buckets them in Africa/Lagos), so the defaults are worked out in that zone too.
const lagosDay = (offsetDays = 0) => {
  const d = new Date(Date.now() + offsetDays * 86400000);
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Lagos' }).format(d); // YYYY-MM-DD
};
const monthStart = () => `${lagosDay().slice(0, 8)}01`;

const DAY_COLUMNS = [
  ['day', 'Day'], ['orders', 'Orders'], ['gross', 'Gross'], ['food_amount', 'Food'], ['delivery_fee', 'Delivery fee'],
  ['commission', 'Commission on food'], ['delivery_commission', 'Commission on delivery'],
  ['platform_income', 'Platform income'], ['restaurant_share', 'Restaurant share'],
];

function Stat({ label, value, note }) {
  return (
    <div className="stat">
      <span className="muted small">{label}</span>
      <strong>{value}</strong>
      {note && <span className="muted small">{note}</span>}
    </div>
  );
}

// One restaurant (restaurantId = a number) or every restaurant (null, admin only): period picker, totals, by-day table, CSV.
export default function ReportView({ restaurantId, title }) {
  const [from, setFrom] = useState(() => lagosDay(-29));
  const [to, setTo] = useState(() => lagosDay());
  const [summary, setSummary] = useState(null);
  const [days, setDays] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!from || !to || from > to) { setError('Choose a start date that is not after the end date.'); setState('error'); return; }
    setState('loading');
    try {
      const [s, d] = await Promise.all([getSummary(restaurantId, from, to), getSalesByDay(restaurantId, from, to)]);
      setSummary(s);
      setDays(d);
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, [restaurantId, from, to]);
  useEffect(() => { load(); }, [load]);

  function preset(f, t) { setFrom(f); setTo(t); }
  const balance = Number(summary?.balance ?? 0);

  return (
    <div>
      <form className="report-filter" onSubmit={(e) => { e.preventDefault(); load(); }}>
        <label className="small">From <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} required /></label>
        <label className="small">To <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} required /></label>
        <div className="inline-actions">
          <button type="button" className="btn btn-small btn-ghost" onClick={() => preset(lagosDay(), lagosDay())}>Today</button>
          <button type="button" className="btn btn-small btn-ghost" onClick={() => preset(lagosDay(-6), lagosDay())}>7 days</button>
          <button type="button" className="btn btn-small btn-ghost" onClick={() => preset(lagosDay(-29), lagosDay())}>30 days</button>
          <button type="button" className="btn btn-small btn-ghost" onClick={() => preset(monthStart(), lagosDay())}>This month</button>
        </div>
      </form>

      {state === 'loading' && <Loading label="Loading report…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && summary && (
        <>
          <div className="stat-grid">
            <Stat label="Orders" value={summary.orders} note={`${summary.online_orders} online · ${summary.cash_orders} cash`} />
            <Stat label="Sales (gross)" value={formatMoney(summary.gross)} note={`Food ${formatMoney(summary.food_amount)} · Delivery ${formatMoney(summary.delivery_fee)}`} />
            <Stat label="Platform income" value={formatMoney(summary.platform_income)} note={`Food ${formatMoney(summary.commission)} · Delivery ${formatMoney(summary.delivery_commission)}`} />
            <Stat label="Restaurant share" value={formatMoney(summary.restaurant_share)} />
            <Stat
              label="Balance"
              value={formatMoney(Math.abs(balance))}
              note={balance === 0 ? 'Nothing owed' : balance > 0 ? 'Platform owes the restaurant (online sales)' : 'Restaurant owes the platform (cash sales)'}
            />
          </div>
          {summary.refunded_orders > 0 && (
            <p className="muted small">{summary.refunded_orders} refunded order(s), {formatMoney(summary.refunded_gross)}, are not counted above.</p>
          )}

          <div className="order-head">
            <h2>{title ?? 'Sales by day'}</h2>
            {days.length > 0 && (
              <button type="button" className="btn btn-small btn-ghost" onClick={() => downloadCsv(`sales-by-day-${from}-to-${to}.csv`, toCsv(days, DAY_COLUMNS))}>
                Download CSV
              </button>
            )}
          </div>
          {days.length === 0 ? (
            <EmptyState title="No sales in this period">Paid online orders and delivered cash orders appear here.</EmptyState>
          ) : (
            <div className="table-wrap">
              <table className="report-table">
                <thead><tr><th>Day</th><th>Orders</th><th>Gross</th><th>Platform income</th><th>Restaurant share</th></tr></thead>
                <tbody>
                  {days.map((d) => (
                    <tr key={d.day}>
                      <td>{d.day}</td><td>{d.orders}</td><td>{formatMoney(d.gross)}</td>
                      <td>{formatMoney(d.platform_income)}</td><td>{formatMoney(d.restaurant_share)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
