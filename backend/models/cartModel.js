const pool = require('../config/db');
const { CART_MAX_QUANTITY } = require('../utils/constants');

// All SQL for carts and cart_items. Every query is tied to a user_id, so a customer can only
// ever reach their own cart.

// Cart lines with the CURRENT menu price (not the price stored when the item was added),
// plus what's needed to tell whether the food can still be bought.
async function findItems(userId) {
  const [rows] = await pool.execute(
    `SELECT ci.cart_item_id, f.food_id, f.food_name, f.image_url, f.price AS unit_price, ci.quantity,
            f.is_available, c.status AS category_status
     FROM carts ca
     JOIN cart_items ci ON ci.cart_id = ca.cart_id
     JOIN food_items f ON f.food_id = ci.food_id
     JOIN categories c ON c.category_id = f.category_id
     WHERE ca.user_id = ?
     ORDER BY ci.cart_item_id`,
    [userId]
  );
  return rows;
}

// One cart line, only if it belongs to this user (otherwise null, same as "doesn't exist").
async function findItem(userId, cartItemId) {
  const [rows] = await pool.execute(
    `SELECT ci.cart_item_id, ci.quantity
     FROM cart_items ci JOIN carts ca ON ca.cart_id = ci.cart_id
     WHERE ci.cart_item_id = ? AND ca.user_id = ?`,
    [cartItemId, userId]
  );
  return rows[0] || null;
}

// Adds `quantity` of a food. The cart is created on first use; a food already in the cart gets
// its quantity increased instead of a second line. All in one transaction: if the new total
// would pass the maximum, everything is rolled back. Returns false in that case.
async function addItem(userId, foodId, quantity) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    // LAST_INSERT_ID(cart_id) makes insertId return the existing cart's id when there already is one.
    const [cart] = await conn.execute(
      'INSERT INTO carts (user_id) VALUES (?) ON DUPLICATE KEY UPDATE cart_id = LAST_INSERT_ID(cart_id)',
      [userId]
    );
    const cartId = cart.insertId;

    // cart_items.price is a copy of the menu price at this moment; totals always use the live price.
    await conn.execute(
      `INSERT INTO cart_items (cart_id, food_id, quantity, price)
       SELECT ?, f.food_id, ?, f.price FROM food_items f WHERE f.food_id = ?
       ON DUPLICATE KEY UPDATE quantity = quantity + VALUES(quantity), price = VALUES(price)`,
      [cartId, quantity, foodId]
    );

    const [[row]] = await conn.execute('SELECT quantity FROM cart_items WHERE cart_id = ? AND food_id = ?', [
      cartId,
      foodId,
    ]);
    if (row.quantity > CART_MAX_QUANTITY) {
      await conn.rollback();
      return false;
    }

    await conn.commit();
    return true;
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }
}

// Sets the quantity exactly, and refreshes the stored price copy.
async function setQuantity(cartItemId, quantity) {
  await pool.execute(
    `UPDATE cart_items ci JOIN food_items f ON f.food_id = ci.food_id
     SET ci.quantity = ?, ci.price = f.price
     WHERE ci.cart_item_id = ?`,
    [quantity, cartItemId]
  );
}

async function removeItem(cartItemId) {
  await pool.execute('DELETE FROM cart_items WHERE cart_item_id = ?', [cartItemId]);
}

module.exports = { findItems, findItem, addItem, setQuantity, removeItem };
