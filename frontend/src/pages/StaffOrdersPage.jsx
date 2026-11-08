import { useCallback, useEffect, useState } from 'react';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import OrderStatusTrack from '../components/OrderStatusTrack';
import { ACTIVE, assignRider, listRiders, listStaffOrders, setOrderStatus } from '../services/orderService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';
import { CAN_ASSIGN, STAFF_ACTIONS, one, statusLabel } from '../utils/orders';

const FILTERS = [
  { key: 'active', label: 'Active', statuses: ACTIVE },
  { key: 'pending', label: 'Pending', statuses: ['pending'] },
  { key: 'confirmed', label: 'Confirmed', statuses: ['confirmed'] },
  { key: 'preparing', label: 'Preparing', statuses: ['preparing'] },
  { key: 'ready', label: 'Ready', statuses: ['ready_for_delivery'] },
  { key: 'out', label: 'Out for delivery', statuses: ['out_for_delivery'] },
  { key: 'done', label: 'Delivered', statuses: ['delivered'] },
  { key: 'closed', label: 'Closed', statuses: ['cancelled', 'rejected', 'failed'] },
  { key: 'all', label: 'All', statuses: null },
];

function OrderRow({ order, riders, onChanged }) {
  const pay = one(order.payments);
  const delivery = one(order.deliveries);
  const customer = one(order.profiles);
  const actions = STAFF_ACTIONS[order.order_status] ?? [];
  const unpaidOnline = pay?.payment_method === 'online' && pay?.payment_status !== 'paid';

  const [reasonFor, setReasonFor] = useState(null); // the action awaiting a reason
  const [reason, setReason] = useState('');
  const [riderId, setRiderId] = useState(delivery?.rider_id ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function run(fn) {
    setBusy(true);
    setError('');
    try {
      await fn();
      setReasonFor(null);
      setReason('');
      await onChanged();
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
    } finally {
      setBusy(false);
    }
  }

  const riderName = (id) => {
    const r = riders.find((x) => x.id === id);
    return r ? `${r.first_name} ${r.last_name}` : 'assigned rider';
  };

  return (
    <li className="order-card">
      <div className="order-head">
        <strong>Order #{order.id}</strong>
        <span className="muted small">{new Date(order.created_at).toLocaleString()}</span>
      </div>
      <OrderStatusTrack status={order.order_status} />
      <p className="small">
        {customer ? `${customer.first_name} ${customer.last_name}` : 'Customer'}
        {customer?.phone && <> · <a href={`tel:${customer.phone}`}>{customer.phone}</a></>}
      </p>
      <p className="muted small">{order.order_items.map((i) => `${i.quantity}× ${i.food_name}`).join(', ')}</p>
      <p className="muted small">
        {order.delivery_street_address}, {order.delivery_city}, {order.delivery_state}
        {order.delivery_landmark ? ` (${order.delivery_landmark})` : ''}
      </p>
      <p>
        <strong>{formatMoney(order.total_amount)}</strong>
        {pay && (
          <span className={`pill ${pay.payment_status === 'paid' ? 'pill-ok' : 'pill-wait'}`}>
            {statusLabel(pay.payment_method)} · {statusLabel(pay.payment_status)}
          </span>
        )}
      </p>

      {actions.length > 0 && (
        <div className="inline-actions">
          {actions.map((a) => {
            const blocked = a.to === 'confirmed' && unpaidOnline;
            return (
              <button
                key={a.to}
                type="button"
                className={`btn btn-small ${a.reason ? 'btn-ghost' : ''}`}
                disabled={busy || blocked}
                title={blocked ? 'Waiting for the online payment' : undefined}
                onClick={() => (a.reason ? setReasonFor(a) : run(() => setOrderStatus(order.id, a.to)))}
              >
                {a.label}
              </button>
            );
          })}
          {unpaidOnline && order.order_status === 'pending' && <span className="muted small">Awaiting online payment</span>}
        </div>
      )}

      {reasonFor && (
        <form
          className="inline-actions"
          onSubmit={(e) => {
            e.preventDefault();
            if (reason.trim()) run(() => setOrderStatus(order.id, reasonFor.to, reason.trim()));
          }}
        >
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder={`Reason to ${reasonFor.label.toLowerCase()} (required)`}
            maxLength={255}
            aria-label="Reason"
            autoFocus
          />
          <button className="btn btn-small btn-danger" type="submit" disabled={busy || !reason.trim()}>Confirm {reasonFor.label.toLowerCase()}</button>
          <button className="btn btn-small btn-ghost" type="button" onClick={() => setReasonFor(null)} disabled={busy}>Back</button>
        </form>
      )}

      {CAN_ASSIGN.includes(order.order_status) && (
        <form
          className="inline-actions"
          onSubmit={(e) => {
            e.preventDefault();
            if (riderId) run(() => assignRider(order.id, riderId));
          }}
        >
          {delivery && <span className="small">Rider: <strong>{riderName(delivery.rider_id)}</strong></span>}
          {riders.length === 0 ? (
            <span className="muted small">No active riders yet.</span>
          ) : (
            <>
              <select value={riderId} onChange={(e) => setRiderId(e.target.value)} aria-label="Choose rider">
                <option value="">{delivery ? 'Change rider…' : 'Choose a rider…'}</option>
                {riders.map((r) => <option key={r.id} value={r.id}>{r.first_name} {r.last_name}</option>)}
              </select>
              <button className="btn btn-small" type="submit" disabled={busy || !riderId || riderId === delivery?.rider_id}>
                {delivery ? 'Reassign' : 'Assign rider'}
              </button>
            </>
          )}
        </form>
      )}
      {!CAN_ASSIGN.includes(order.order_status) && delivery && (
        <p className="small">Rider: <strong>{riderName(delivery.rider_id)}</strong> ({statusLabel(delivery.delivery_status)})</p>
      )}
      {error && <p className="field-error" role="alert">{error}</p>}
    </li>
  );
}

export default function StaffOrdersPage() {
  const [filterKey, setFilterKey] = useState('active');
  const [orders, setOrders] = useState([]);
  const [riders, setRiders] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try {
      const statuses = FILTERS.find((f) => f.key === filterKey).statuses;
      const [o, r] = await Promise.all([listStaffOrders(statuses), listRiders()]);
      setOrders(o);
      setRiders(r);
      setState('ready');
    } catch (e) {
      console.error(e);
      setError(friendlyDbError(e));
      setState('error');
    }
  }, [filterKey]);

  useEffect(() => {
    load();
    const t = setInterval(() => load(true), 30000); // new orders appear without a manual refresh
    return () => clearInterval(t);
  }, [load]);

  return (
    <section>
      <div className="order-head">
        <h1>Orders</h1>
        <button type="button" className="btn btn-ghost btn-small" onClick={() => load()}>Refresh</button>
      </div>
      <div className="tabs" role="tablist" aria-label="Order filter">
        {FILTERS.map((f) => (
          <button key={f.key} type="button" role="tab" aria-selected={f.key === filterKey} className={`tab ${f.key === filterKey ? 'tab-on' : ''}`} onClick={() => setFilterKey(f.key)}>
            {f.label}
          </button>
        ))}
      </div>
      {state === 'loading' && <Loading label="Loading orders…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && orders.length === 0 && <EmptyState title="No orders here" />}
      {state === 'ready' && orders.length > 0 && (
        <ul className="cart-list">
          {orders.map((o) => <OrderRow key={`${o.id}-${o.order_status}`} order={o} riders={riders} onChanged={() => load(true)} />)}
        </ul>
      )}
    </section>
  );
}
