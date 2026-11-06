const pool = require('../config/db');

// SQL for payment_refunds. `db` can be the pool or a transaction connection.

const SELECT = `
  SELECT r.refund_id, r.payment_id, r.transaction_reference, r.amount, r.refund_status,
         r.paystack_refund_id, r.reason, r.requested_by, r.created_at, r.updated_at
  FROM payment_refunds r`;

async function findByReference(reference, db = pool, { forUpdate = false } = {}) {
  const [rows] = await db.execute(`${SELECT} WHERE r.transaction_reference = ?${forUpdate ? ' FOR UPDATE' : ''}`, [reference]);
  return rows[0] || null;
}

async function findById(refundId) {
  const [rows] = await pool.execute(`${SELECT} WHERE r.refund_id = ?`, [refundId]);
  return rows[0] || null;
}

async function listByPaymentId(paymentId) {
  const [rows] = await pool.execute(`${SELECT} WHERE r.payment_id = ? ORDER BY r.refund_id`, [paymentId]);
  return rows;
}

async function insert(db, { paymentId, reference, amount, reason, requestedBy }) {
  const [result] = await db.execute(
    'INSERT INTO payment_refunds (payment_id, transaction_reference, amount, reason, requested_by) VALUES (?, ?, ?, ?, ?)',
    [paymentId, reference, amount, reason, requestedBy]
  );
  return result.insertId;
}

// A failed refund can be tried again: the same row goes back to pending.
async function reopen(db, refundId, { reason, requestedBy }) {
  await db.execute(
    "UPDATE payment_refunds SET refund_status = 'pending', paystack_refund_id = NULL, reason = ?, requested_by = ? WHERE refund_id = ?",
    [reason, requestedBy, refundId]
  );
}

async function setStatus(db, refundId, status) {
  await db.execute('UPDATE payment_refunds SET refund_status = ? WHERE refund_id = ?', [status, refundId]);
}

async function setPaystackId(refundId, paystackRefundId) {
  await pool.execute('UPDATE payment_refunds SET paystack_refund_id = ? WHERE refund_id = ?', [String(paystackRefundId).slice(0, 50), refundId]);
}

module.exports = { findByReference, findById, listByPaymentId, insert, reopen, setStatus, setPaystackId };
