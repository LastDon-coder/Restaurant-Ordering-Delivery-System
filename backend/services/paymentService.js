const crypto = require('node:crypto');
const pool = require('../config/db');
const AppError = require('../utils/AppError');
const { ROLES } = require('../utils/constants');
const { toMinor } = require('../utils/money');
const { paystack } = require('../config/env');
const paystackService = require('./paystackService');
const paymentModel = require('../models/paymentModel');

// A reference looks like ORD-12-9f86d081884c7d65: the order id is part of it, so even if a customer pays an
// older attempt, we still know which order the money is for.
const REFERENCE_RE = /^ORD-(\d{1,10})-[a-f0-9]{16}$/;
const CURRENCY = 'NGN';
const CLOSED_ORDER = ['cancelled', 'rejected', 'failed'];

function summary(p) {
  return {
    order_id: p.order_id,
    order_status: p.order_status,
    payment_method: p.payment_method,
    payment_status: p.payment_status,
    amount: p.amount,
    paid_at: p.paid_at,
    reference: p.transaction_reference,
  };
}

// The ONE place a payment becomes "paid". Both the verify endpoint and the webhook call it with what Paystack
// says happened, so the rules are identical and running it twice is harmless (idempotent).
// tx = { reference, status, amount (kobo), currency }. Returns an outcome string.
async function applyPaystackResult(tx) {
  const match = REFERENCE_RE.exec(tx.reference || '');
  if (!match) return 'ignored';

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    // Lock the payment row: the webhook and a verify call arriving together are handled one after the other.
    const payment = await paymentModel.findByOrderId(Number(match[1]), conn, { forUpdate: true });
    if (!payment || payment.payment_method !== 'online') {
      await conn.commit();
      return 'ignored';
    }

    let outcome = 'pending';
    if (payment.payment_status === 'paid') {
      if (tx.status === 'success' && payment.transaction_reference !== tx.reference) {
        // The customer paid twice (e.g. two checkout tabs). We keep the first; the second needs a manual refund.
        console.error(`DUPLICATE PAYMENT for order ${payment.order_id}: ${tx.reference} also succeeded. Refund it in the Paystack dashboard.`);
      }
      outcome = 'already_paid';
    } else if (tx.status === 'success') {
      // Never trust "success" alone: the amount and currency must be exactly what we asked for.
      if (tx.amount !== toMinor(payment.amount) || tx.currency !== CURRENCY) {
        console.error(`PAYMENT MISMATCH for order ${payment.order_id}: expected ${toMinor(payment.amount)} ${CURRENCY}, Paystack says ${tx.amount} ${tx.currency} (${tx.reference})`);
        outcome = 'mismatch';
      } else {
        await conn.execute(
          "UPDATE payments SET payment_status = 'paid', paid_at = NOW(), transaction_reference = ? WHERE payment_id = ?",
          [tx.reference, payment.payment_id]
        );
        if (CLOSED_ORDER.includes(payment.order_status)) {
          console.error(`Order ${payment.order_id} is ${payment.order_status} but was paid (${tx.reference}). Refund it in the Paystack dashboard.`);
        }
        outcome = 'paid';
      }
    } else if (tx.status === 'failed' && payment.transaction_reference === tx.reference) {
      await conn.execute("UPDATE payments SET payment_status = 'failed' WHERE payment_id = ?", [payment.payment_id]);
      outcome = 'failed';
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

// POST /payments/initialize: start paying for one of the customer's online orders.
async function initializePayment(user, orderId) {
  const payment = await paymentModel.findByOrderId(orderId);
  // Someone else's order looks exactly like a missing one.
  if (!payment || payment.user_id !== user.user_id) throw new AppError('Order not found', 404);
  if (payment.payment_method !== 'online') throw new AppError('This order is not set to online payment', 400);
  if (payment.payment_status === 'paid') throw new AppError('This order has already been paid', 409);
  if (payment.order_status !== 'pending') {
    throw new AppError(`This order is ${payment.order_status}, so it can no longer be paid`, 409);
  }

  // A previous attempt may have succeeded without us hearing yet. Ask Paystack before starting another.
  if (payment.transaction_reference) {
    const earlier = await paystackService.verifyTransaction(payment.transaction_reference);
    if (earlier && earlier.status === 'success') {
      const outcome = await applyPaystackResult({
        reference: earlier.reference, status: earlier.status, amount: earlier.amount, currency: earlier.currency,
      });
      if (outcome === 'paid' || outcome === 'already_paid') throw new AppError('This order has already been paid', 409);
    }
  }

  const reference = `ORD-${orderId}-${crypto.randomBytes(8).toString('hex')}`;
  // Saved BEFORE calling Paystack, so a webhook can always find it even if our request below is cut off.
  if (!(await paymentModel.setReference(orderId, reference))) throw new AppError('This order has already been paid', 409);

  // The amount comes from OUR payment row (calculated at checkout), never from the client.
  const data = await paystackService.initializeTransaction({
    email: user.email,
    amountKobo: toMinor(payment.amount),
    reference,
    callbackUrl: paystack.callbackUrl,
    metadata: { order_id: orderId, user_id: user.user_id },
  });
  return {
    authorization_url: data.authorization_url,
    access_code: data.access_code,
    reference,
    amount: payment.amount,
    currency: CURRENCY,
  };
}

// GET /payments/verify/:reference: the customer's browser came back from Paystack; confirm with Paystack directly.
async function verifyPayment(user, reference) {
  const payment = await paymentModel.findByReference(reference);
  if (!payment || (user.role === ROLES.CUSTOMER && payment.user_id !== user.user_id)) {
    throw new AppError('Payment not found', 404);
  }

  const tx = await paystackService.verifyTransaction(reference);
  if (tx) {
    const outcome = await applyPaystackResult({
      reference: tx.reference || reference, status: tx.status, amount: tx.amount, currency: tx.currency,
    });
    if (outcome === 'mismatch') {
      throw new AppError('The amount paid does not match this order. Please contact the restaurant.', 409);
    }
  }
  return summary(await paymentModel.findByOrderId(payment.order_id));
}

// POST /payments/webhook: Paystack tells us, server to server. Returns a short string describing what happened.
async function handleWebhookEvent(event) {
  if (!event || event.event !== 'charge.success' || !event.data) return 'ignored';
  const d = event.data;
  if (typeof d.reference !== 'string') return 'ignored';
  return applyPaystackResult({ reference: d.reference, status: d.status, amount: Number(d.amount), currency: d.currency });
}

module.exports = { initializePayment, verifyPayment, handleWebhookEvent, REFERENCE_RE };
