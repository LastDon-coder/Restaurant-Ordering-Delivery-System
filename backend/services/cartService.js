const { deliveryFee } = require('../config/env');
const { toMinor, fromMinor } = require('../utils/money');

// Turns cart rows from the database into what the API returns, including the totals.
// The server does ALL the money maths (never the client), using exact whole-kobo amounts.
//
// Rules:
// - Prices come from the live menu, so a price change shows up in the cart immediately.
// - A food that is now sold out (or whose category is hidden) stays visible in the cart with
//   is_available: false, but is NOT counted in the totals.
// - The flat delivery fee (DELIVERY_FEE in .env) applies only when there is something to deliver.
// - Discounts don't exist yet in version 1, so discount is always "0.00".
function buildCart(rows) {
  let subtotal = 0;
  let itemCount = 0;

  const items = rows.map((row) => {
    const onSale = Boolean(row.is_available) && row.category_status === 'active';
    const lineTotal = toMinor(row.unit_price) * row.quantity;
    if (onSale) {
      subtotal += lineTotal;
      itemCount += row.quantity;
    }
    return {
      cart_item_id: row.cart_item_id,
      food_id: row.food_id,
      food_name: row.food_name,
      image_url: row.image_url,
      unit_price: row.unit_price,
      quantity: row.quantity,
      line_total: fromMinor(lineTotal),
      is_available: onSale,
    };
  });

  const fee = subtotal > 0 ? toMinor(deliveryFee) : 0;
  const discount = 0;

  return {
    items,
    summary: {
      item_count: itemCount,
      subtotal: fromMinor(subtotal),
      delivery_fee: fromMinor(fee),
      discount: fromMinor(discount),
      total: fromMinor(subtotal + fee - discount),
    },
  };
}

module.exports = { buildCart };
