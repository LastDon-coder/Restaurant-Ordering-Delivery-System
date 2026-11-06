// Role names exactly as stored in the roles table.
const ROLES = {
  ADMIN: 'admin',
  STAFF: 'staff',
  CUSTOMER: 'customer',
  RIDER: 'rider',
};

// Most of one food a customer can put in the cart (and later order) at once.
const CART_MAX_QUANTITY = 50;

// Order lifecycle (same values as the orders.order_status ENUM).
const ORDER_STATUSES = [
  'pending',
  'confirmed',
  'preparing',
  'ready_for_delivery',
  'out_for_delivery',
  'delivered',
  'cancelled',
  'rejected',
  'failed',
];

// Ways to pay that customers may choose. (bank_transfer exists in the table but is not offered in V1.)
const PAYMENT_METHODS = ['online', 'cash_on_delivery'];

module.exports = { ROLES, CART_MAX_QUANTITY, ORDER_STATUSES, PAYMENT_METHODS };
