// Role names exactly as stored in the roles table.
const ROLES = {
  ADMIN: 'admin',
  STAFF: 'staff',
  CUSTOMER: 'customer',
  RIDER: 'rider',
};

// Most of one food a customer can put in the cart (and later order) at once.
const CART_MAX_QUANTITY = 50;

module.exports = { ROLES, CART_MAX_QUANTITY };
