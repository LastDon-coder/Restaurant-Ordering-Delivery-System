const { z } = require('zod');
const { REFERENCE_RE } = require('./paymentRefs');

// Only WHICH order to pay. The amount is never accepted from the client: the server uses the order's own total.
const initializePaymentSchema = z.object({
  order_id: z
    .number({ error: 'Order id is required' })
    .int('Order id must be a whole number')
    .positive('Order id must be a positive number'),
});

// Refund: why, and (only for a duplicate payment) which reference. Without a reference the order's own payment is refunded.
const refundSchema = z.object({
  reason: z
    .string({ error: 'Reason is required' })
    .trim()
    .min(3, 'Reason must be at least 3 characters')
    .max(255, 'Reason must be at most 255 characters'),
  reference: z.string({ error: 'Reference must be text' }).trim().regex(REFERENCE_RE, 'Invalid payment reference').optional(),
});

module.exports = { initializePaymentSchema, refundSchema };
