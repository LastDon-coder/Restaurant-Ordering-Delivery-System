// PostgREST returns a single object for one-to-one embeds (payments, deliveries) and an array otherwise.
export const one = (x) => (Array.isArray(x) ? x[0] : x) ?? null;
export const statusLabel = (s) => (s ? s.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase()) : '—');
export const STEPS = ['pending', 'confirmed', 'preparing', 'ready_for_delivery', 'out_for_delivery', 'delivered'];
export const CLOSED = ['cancelled', 'rejected', 'failed'];

// What the restaurant staff UI offers per status. The database is the real gatekeeper (change_order_status);
// out_for_delivery / delivered / failed belong to the rider, so staff never see them.
export const STAFF_ACTIONS = {
  pending: [{ to: 'confirmed', label: 'Confirm' }, { to: 'rejected', label: 'Reject', reason: true }],
  confirmed: [{ to: 'preparing', label: 'Start preparing' }, { to: 'cancelled', label: 'Cancel', reason: true }],
  preparing: [{ to: 'ready_for_delivery', label: 'Mark ready' }, { to: 'cancelled', label: 'Cancel', reason: true }],
  ready_for_delivery: [{ to: 'cancelled', label: 'Cancel', reason: true }],
};
export const CAN_ASSIGN = ['confirmed', 'preparing', 'ready_for_delivery'];
