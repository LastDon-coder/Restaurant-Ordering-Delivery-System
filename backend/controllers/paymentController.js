const AppError = require('../utils/AppError');
const { sendSuccess } = require('../utils/response');
const paystackService = require('../services/paystackService');
const paymentService = require('../services/paymentService');

// POST /api/v1/payments/initialize   { order_id }   (customer)
async function initialize(req, res) {
  const payment = await paymentService.initializePayment(req.user, req.body.order_id);
  sendSuccess(res, 200, 'Payment started. Send the customer to authorization_url', { payment });
}

// GET /api/v1/payments/verify/:reference   (the customer who owns it, admin, staff)
async function verify(req, res) {
  const payment = await paymentService.verifyPayment(req.user, req.params.reference);
  sendSuccess(res, 200, 'Payment status retrieved', { payment });
}

// POST /api/v1/payments/webhook   (Paystack only; no login, the signature is the proof)
async function webhook(req, res) {
  // req.body is the raw Buffer here (see app.js).
  if (!paystackService.verifyWebhookSignature(req.body, req.get('x-paystack-signature'))) {
    throw new AppError('Invalid signature', 401);
  }
  let event;
  try {
    event = JSON.parse(req.body.toString('utf8'));
  } catch {
    throw new AppError('Invalid JSON in request body', 400);
  }
  // A mismatch or unknown reference is logged and still answered 200: retrying the same event can never fix it.
  // A database error is thrown (500) so Paystack retries later.
  const outcome = await paymentService.handleWebhookEvent(event);
  sendSuccess(res, 200, `Webhook processed: ${outcome}`);
}

module.exports = { initialize, verify, webhook };
