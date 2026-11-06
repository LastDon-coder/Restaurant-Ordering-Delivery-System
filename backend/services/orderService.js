const pool = require('../config/db');
const AppError = require('../utils/AppError');
const { buildCart } = require('./cartService');
const { ROLES } = require('../utils/constants');
const { TRANSITIONS, canPerform, needsReason } = require('../utils/orderWorkflow');

// Turns the customer's cart into an order. Everything happens in ONE transaction:
// either the address, order, order items, payment AND the emptied cart are all saved, or none are.
// Without that, a crash half-way could leave an order with no items, or a charged cart that is not cleared.
async function placeOrder(userId, { delivery_address: addr, payment_method }) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    // Lock this customer's cart row. A double-click (two requests at once) now queues up: the
    // second one only runs after the first commits, finds an empty cart and is refused.
    const [carts] = await conn.execute('SELECT cart_id FROM carts WHERE user_id = ? FOR UPDATE', [userId]);
    if (!carts[0]) throw new AppError('Your cart is empty', 400);
    const cartId = carts[0].cart_id;

    // Read the cart with CURRENT menu prices and lock those food rows, so an admin can't change a
    // price between us adding up the total and saving the order. (Ordered by id so two orders
    // locking the same foods always lock them in the same order, which avoids deadlocks.)
    const [rows] = await conn.execute(
      `SELECT ci.cart_item_id, f.food_id, f.food_name, f.image_url, f.price AS unit_price, ci.quantity,
              f.is_available, c.status AS category_status
       FROM cart_items ci
       JOIN food_items f ON f.food_id = ci.food_id
       JOIN categories c ON c.category_id = f.category_id
       WHERE ci.cart_id = ?
       ORDER BY f.food_id
       FOR UPDATE`,
      [cartId]
    );
    if (rows.length === 0) throw new AppError('Your cart is empty', 400);

    const cart = buildCart(rows);
    const unavailable = cart.items.filter((item) => !item.is_available);
    if (unavailable.length > 0) {
      throw new AppError(
        'Some items in your cart are no longer available',
        400,
        unavailable.map((item) => ({ field: 'cart', message: `"${item.food_name}" is no longer available. Remove it from your cart.` }))
      );
    }
    const { subtotal, delivery_fee, discount, total } = cart.summary;

    // orders.address_id is required, so the address the customer typed is saved as an address row.
    const [address] = await conn.execute(
      'INSERT INTO addresses (user_id, street_address, city, state, landmark) VALUES (?, ?, ?, ?, ?)',
      [userId, addr.street_address, addr.city, addr.state, addr.landmark ?? null]
    );

    // The delivery_* columns are a COPY of the address, so the order keeps showing where it was
    // delivered even if the address row is edited later.
    const [order] = await conn.execute(
      `INSERT INTO orders (user_id, address_id, subtotal, delivery_fee, discount, total_amount,
                           delivery_street_address, delivery_city, delivery_state, delivery_landmark)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [userId, address.insertId, subtotal, delivery_fee, discount, total, addr.street_address, addr.city, addr.state, addr.landmark ?? null]
    );
    const orderId = order.insertId;

    // Snapshot: name and price are copied into order_items, so later menu changes never rewrite history.
    const placeholders = cart.items.map(() => '(?, ?, ?, ?, ?)').join(', ');
    const values = cart.items.flatMap((i) => [orderId, i.food_id, i.food_name, i.quantity, i.unit_price]);
    await conn.execute(`INSERT INTO order_items (order_id, food_id, food_name, quantity, price) VALUES ${placeholders}`, values);

    // One payment row per order (UNIQUE order_id). It starts 'pending' either way: online payments are
    // verified with the payment provider in Step 14, cash is collected on delivery.
    await conn.execute('INSERT INTO payments (order_id, payment_method, amount) VALUES (?, ?, ?)', [orderId, payment_method, total]);

    // First line of the order's history: placed by the customer, starting as pending.
    await conn.execute(
      "INSERT INTO order_status_history (order_id, from_status, to_status, changed_by) VALUES (?, NULL, 'pending', ?)",
      [orderId, userId]
    );

    await conn.execute('DELETE FROM cart_items WHERE cart_id = ?', [cartId]);

    await conn.commit();
    return orderId;
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }
}

// Moves an order to a new status, checking the rules. Also in one transaction: the status change and its
// history line are saved together or not at all.
async function changeStatus({ orderId, user, newStatus, reason }) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    // Lock the order row. Two people pressing buttons at once (say staff confirm while the customer
    // cancels) are handled one after the other, and the second one is judged on the NEW status.
    const [rows] = await conn.execute(
      `SELECT o.order_id, o.user_id, o.order_status, p.payment_method, p.payment_status
       FROM orders o LEFT JOIN payments p ON p.order_id = o.order_id
       WHERE o.order_id = ? FOR UPDATE`,
      [orderId]
    );
    const order = rows[0];
    // Someone else's order looks exactly like a missing one.
    if (!order || (user.role === ROLES.CUSTOMER && order.user_id !== user.user_id)) {
      throw new AppError('Order not found', 404);
    }

    const from = order.order_status;
    if (!TRANSITIONS[from].includes(newStatus)) {
      const next = TRANSITIONS[from].length ? TRANSITIONS[from].join(', ') : 'none (this order is final)';
      throw new AppError(`Cannot change an order from ${from} to ${newStatus}. Allowed next: ${next}`, 409);
    }
    if (!canPerform(user.role, from, newStatus)) {
      throw new AppError('You are not allowed to make this status change', 403);
    }
    if (needsReason(user.role, newStatus) && !reason) {
      throw new AppError('Validation failed', 400, [{ field: 'reason', message: `A reason is required when the status is ${newStatus}` }]);
    }
    // An online order must be PAID (verified by the server in Step 14) before the kitchen starts on it.
    if (newStatus === 'confirmed' && order.payment_method === 'online' && order.payment_status !== 'paid') {
      throw new AppError('This is an online-payment order and it has not been paid yet', 409);
    }

    await conn.execute('UPDATE orders SET order_status = ? WHERE order_id = ?', [newStatus, orderId]);
    // Cash is handed over at the door, so a delivered cash-on-delivery order counts as paid.
    if (newStatus === 'delivered' && order.payment_method === 'cash_on_delivery' && order.payment_status === 'pending') {
      await conn.execute("UPDATE payments SET payment_status = 'paid', paid_at = NOW() WHERE order_id = ?", [orderId]);
    }
    await conn.execute(
      'INSERT INTO order_status_history (order_id, from_status, to_status, changed_by, reason) VALUES (?, ?, ?, ?, ?)',
      [orderId, from, newStatus, user.user_id, reason ?? null]
    );

    await conn.commit();
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }
}

module.exports = { placeOrder, changeStatus };
