const pool = require('../config/db');

// SQL for payments. Each payment belongs to one order (UNIQUE order_id) and carries the order's
// owner and status, because the callers need both to decide what is allowed.

const SELECT = `
  SELECT p.payment_id, p.order_id, p.payment_method, p.transaction_reference, p.amount,
         p.payment_status, p.paid_at, o.user_id, o.order_status
  FROM payments p JOIN orders o ON o.order_id = p.order_id`;

// `db` can be the pool or a transaction connection. forUpdate locks the rows until the transaction ends.
async function findByOrderId(orderId, db = pool, { forUpdate = false } = {}) {
  const [rows] = await db.execute(`${SELECT} WHERE p.order_id = ?${forUpdate ? ' FOR UPDATE' : ''}`, [orderId]);
  return rows[0] || null;
}

async function findByReference(reference) {
  const [rows] = await pool.execute(`${SELECT} WHERE p.transaction_reference = ?`, [reference]);
  return rows[0] || null;
}

// Remembers the reference of a payment attempt. Does nothing (returns false) if the order is already paid.
async function setReference(orderId, reference) {
  const [result] = await pool.execute(
    "UPDATE payments SET transaction_reference = ?, payment_status = 'pending' WHERE order_id = ? AND payment_status <> 'paid'",
    [reference, orderId]
  );
  return result.affectedRows === 1;
}

module.exports = { findByOrderId, findByReference, setReference };
