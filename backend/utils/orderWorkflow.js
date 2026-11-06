const { ROLES } = require('./constants');

// The order status rules in one place. Each status lists the statuses it may move to next.
// Delivered, cancelled, rejected and failed are final: nothing leaves them.
const TRANSITIONS = {
  pending: ['confirmed', 'rejected', 'cancelled'],
  confirmed: ['preparing', 'cancelled'],
  preparing: ['ready_for_delivery', 'cancelled'],
  ready_for_delivery: ['out_for_delivery', 'cancelled'],
  out_for_delivery: ['delivered', 'failed'],
  delivered: [],
  cancelled: [],
  rejected: [],
  failed: [],
};

// Moves that need a written reason (so the customer can be told why).
// A customer cancelling their own order doesn't have to give one.
const REASON_REQUIRED = new Set(['rejected', 'cancelled', 'failed']);

// Who may make a move. Customers: only cancel, and only their own order while it is still pending.
// Staff and admin: any valid move for now. In Step 15 the two delivery moves go to the assigned rider.
function canPerform(role, fromStatus, toStatus) {
  if (role === ROLES.ADMIN || role === ROLES.STAFF) return true;
  if (role === ROLES.CUSTOMER) return fromStatus === 'pending' && toStatus === 'cancelled';
  return false;
}

function needsReason(role, toStatus) {
  return REASON_REQUIRED.has(toStatus) && role !== ROLES.CUSTOMER;
}

module.exports = { TRANSITIONS, canPerform, needsReason };
