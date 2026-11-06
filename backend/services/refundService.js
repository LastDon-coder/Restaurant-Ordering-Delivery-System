const pool = require('../config/db');
const AppError = require('../utils/AppError');
const { fromMinor } = require('../utils/money');
const { REFERENCE_RE } = require('../utils/paymentRefs');
const paystackService = require('./paystackService');
const paymentModel = require('../models/paymentModel');
const refundModel = require('../models/refundModel');

const CLOSED_ORDER = ['cancelled', 'rejected', 'failed'];

function toRefund(row) {
  return {
    refund_id: row.refund_id,
    reference: row.transaction_reference,
    amount: row.amount,
    refund_status: row.refund_status,
    reason: row.reason,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

// Admin refunds a payment, in full. Two cases:
//  1. No reference: refund the order's own recorded payment. The order must already be cancelled, rejected or
//     failed, so nobody refunds an order that is still being cooked.
//  2. A reference: refund a DUPLICATE payment (the customer paid the same order twice). Paystack is asked to
//     confirm that payment really succeeded, so a made-up reference can't be used.
// The money goes back to the customer's original card or bank, via Paystack. It is not instant: Paystack queues it
// and tells us by webhook when it is processed (or failed).
async function refundPayment(admin, orderId, { reason, reference }) {
  const payment = await paymentModel.findByOrderId(orderId);
  if (!payment) throw new AppError('Order not found', 404);
  if (payment.payment_method !== 'online') {
    throw new AppError('Only online payments can be refunded here. Cash on delivery has nothing to refund through Paystack', 400);
  }

  const duplicate = Boolean(reference) && reference !== payment.transaction_reference;
  let target;
  let amount;
  if (duplicate) {
    const match = REFERENCE_RE.exec(reference);
    if (!match || Number(match[1]) !== orderId) {
      throw new AppError('Validation failed', 400, [{ field: 'reference', message: 'This reference does not belong to this order' }]);
    }
    const tx = await paystackService.verifyTransaction(reference);
    if (!tx || tx.status !== 'success' || tx.currency !== 'NGN') {
      throw new AppError('Paystack has no successful payment with that reference', 409);
    }
    target = reference;
    amount = fromMinor(tx.amount);
  } else {
    assertRefundable(payment);
    target = payment.transaction_reference;
    amount = payment.amount;
  }

  // Reserve the refund BEFORE calling Paystack, with the payment row locked. A double click, or two admins at once,
  // can't both get through: the second finds the reservation and is refused.
  const conn = await pool.getConnection();
  let refundId;
  try {
    await conn.beginTransaction();
    const locked = await paymentModel.findByOrderId(orderId, conn, { forUpdate: true });
    if (!duplicate) assertRefundable(locked);
    const existing = await refundModel.findByReference(target, conn, { forUpdate: true });
    if (existing && existing.refund_status !== 'failed') {
      throw new AppError('A refund for this payment is already in progress or done', 409);
    }
    if (existing) {
      await refundModel.reopen(conn, existing.refund_id, { reason, requestedBy: admin.user_id });
      refundId = existing.refund_id;
    } else {
      refundId = await refundModel.insert(conn, {
        paymentId: payment.payment_id, reference: target, amount, reason, requestedBy: admin.user_id,
      });
    }
    await conn.commit();
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }

  try {
    const data = await paystackService.createRefund({ reference: target, note: reason });
    if (data.id !== undefined && data.id !== null) await refundModel.setPaystackId(refundId, data.id);
  } catch (err) {
    // Paystack clearly said no: mark failed so it can be tried again. If we never heard back, leave it pending:
    // it may have gone through, and Paystack's webhook (or the dashboard) will settle it.
    if (err.rejected) await refundModel.setStatus(pool, refundId, 'failed');
    throw err;
  }
  return toRefund(await refundModel.findById(refundId));
}

function assertRefundable(payment) {
  if (payment.payment_status === 'refunded') throw new AppError('This payment has already been refunded', 409);
  if (payment.payment_status !== 'paid') throw new AppError('This order has not been paid, so there is nothing to refund', 409);
  if (!CLOSED_ORDER.includes(payment.order_status)) {
    throw new AppError(`Cancel or reject the order before refunding it (it is ${payment.order_status})`, 409);
  }
}

async function listRefunds(orderId) {
  const payment = await paymentModel.findByOrderId(orderId);
  if (!payment) throw new AppError('Order not found', 404);
  return (await refundModel.listByPaymentId(payment.payment_id)).map(toRefund);
}

// Paystack webhook: refund.processed (money is on its way back) or refund.failed. Safe to run twice.
// Paystack's payload names the ORIGINAL payment's reference; the documented spelling varies, so accept both.
async function handleRefundEvent(event) {
  const d = event.data || {};
  const reference = d.transaction_reference || (d.transaction && d.transaction.reference) || (typeof d.transaction === 'string' ? d.transaction : null);
  if (typeof reference !== 'string') return 'ignored';
  if (event.event !== 'refund.processed' && event.event !== 'refund.failed') return 'ignored'; // pending/processing: nothing to do

  const known = await refundModel.findByReference(reference);
  if (!known) return 'ignored';

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    // Same lock order as refundPayment (payment row, then refund row) so the two can never deadlock.
    const payment = await paymentModel.findByOrderId((await orderIdOf(conn, known.payment_id)), conn, { forUpdate: true });
    const refund = await refundModel.findByReference(reference, conn, { forUpdate: true });

    let outcome = 'unchanged';
    if (event.event === 'refund.processed') {
      if (refund.refund_status !== 'processed') await refundModel.setStatus(conn, refund.refund_id, 'processed');
      // Only the order's own recorded payment flips the payment to refunded. A refunded duplicate leaves it paid.
      if (payment.transaction_reference === reference && payment.payment_status === 'paid') {
        await conn.execute("UPDATE payments SET payment_status = 'refunded' WHERE payment_id = ?", [payment.payment_id]);
      }
      outcome = 'refund_processed';
    } else if (refund.refund_status === 'pending') {
      await refundModel.setStatus(conn, refund.refund_id, 'failed'); // a processed refund is never downgraded
      console.error(`REFUND FAILED for ${reference}. Check the Paystack dashboard, then try the refund again.`);
      outcome = 'refund_failed';
    }
    await conn.commit();
    return outcome;
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }
}

async function orderIdOf(conn, paymentId) {
  const [rows] = await conn.execute('SELECT order_id FROM payments WHERE payment_id = ?', [paymentId]);
  return rows[0].order_id;
}

module.exports = { refundPayment, listRefunds, handleRefundEvent };
