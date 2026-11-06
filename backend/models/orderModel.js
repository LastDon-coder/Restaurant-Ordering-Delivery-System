const pool = require('../config/db');

// Read queries for orders. (Creating an order is a multi-table transaction: see services/orderService.js.)
// Money columns come back from MySQL as strings ("3500.00"), which is what the API returns.

const ORDER_SELECT = `
  SELECT o.order_id, o.user_id, o.order_status, o.subtotal, o.delivery_fee, o.discount, o.total_amount,
         o.delivery_street_address, o.delivery_city, o.delivery_state, o.delivery_landmark,
         o.created_at, o.updated_at,
         u.first_name, u.last_name, u.phone,
         p.payment_method, p.payment_status, p.amount AS payment_amount, p.paid_at
  FROM orders o
  JOIN users u ON u.user_id = o.user_id
  LEFT JOIN payments p ON p.order_id = o.order_id`;

function toOrder(row, items, history) {
  return {
    order_id: row.order_id,
    order_status: row.order_status,
    subtotal: row.subtotal,
    delivery_fee: row.delivery_fee,
    discount: row.discount,
    total_amount: row.total_amount,
    delivery_address: {
      street_address: row.delivery_street_address,
      city: row.delivery_city,
      state: row.delivery_state,
      landmark: row.delivery_landmark,
    },
    customer: { user_id: row.user_id, first_name: row.first_name, last_name: row.last_name, phone: row.phone },
    payment: {
      payment_method: row.payment_method,
      payment_status: row.payment_status,
      amount: row.payment_amount,
      paid_at: row.paid_at,
      // True when money was taken online for an order that is now cancelled/rejected/failed: an admin should refund it.
      refund_due:
        row.payment_method === 'online' &&
        row.payment_status === 'paid' &&
        ['cancelled', 'rejected', 'failed'].includes(row.order_status),
    },
    items,
    status_history: history,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

// One order with its items. Returns null if there is no such order.
// (The controller decides whether the caller may see it.)
async function findById(orderId) {
  const [rows] = await pool.execute(`${ORDER_SELECT} WHERE o.order_id = ?`, [orderId]);
  if (!rows[0]) return null;
  const [items] = await pool.execute(
    `SELECT food_id, food_name, quantity, price AS unit_price, subtotal AS line_total
     FROM order_items WHERE order_id = ? ORDER BY order_item_id`,
    [orderId]
  );
  // The story of the order, oldest first. Who made each change is deliberately not shown here.
  const [history] = await pool.execute(
    `SELECT from_status, to_status, reason, created_at
     FROM order_status_history WHERE order_id = ? ORDER BY history_id`,
    [orderId]
  );
  return toOrder(rows[0], items, history);
}

// A page of orders, newest first. userId limits it to one customer's orders.
async function list({ userId, status, page, limit }) {
  const where = [];
  const params = [];
  if (userId) {
    where.push('o.user_id = ?');
    params.push(userId);
  }
  if (status) {
    where.push('o.order_status = ?');
    params.push(status);
  }
  const whereSql = where.length > 0 ? `WHERE ${where.join(' AND ')}` : '';

  const [[{ total }]] = await pool.execute(`SELECT COUNT(*) AS total FROM orders o ${whereSql}`, params);
  // query() because LIMIT/OFFSET placeholders are fussy in prepared statements (page/limit are validated numbers).
  const [rows] = await pool.query(
    `SELECT o.order_id, o.user_id, o.order_status, o.total_amount, o.created_at,
            u.first_name, u.last_name,
            p.payment_method, p.payment_status,
            (SELECT COALESCE(SUM(oi.quantity), 0) FROM order_items oi WHERE oi.order_id = o.order_id) AS item_count
     FROM orders o
     JOIN users u ON u.user_id = o.user_id
     LEFT JOIN payments p ON p.order_id = o.order_id
     ${whereSql}
     ORDER BY o.created_at DESC, o.order_id DESC
     LIMIT ? OFFSET ?`,
    [...params, limit, (page - 1) * limit]
  );
  const orders = rows.map((r) => ({
    order_id: r.order_id,
    order_status: r.order_status,
    total_amount: r.total_amount,
    item_count: Number(r.item_count),
    payment_method: r.payment_method,
    payment_status: r.payment_status,
    customer: { user_id: r.user_id, first_name: r.first_name, last_name: r.last_name },
    created_at: r.created_at,
  }));
  return { orders, total };
}

module.exports = { findById, list };
