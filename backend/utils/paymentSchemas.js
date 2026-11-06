const { z } = require('zod');

// Only WHICH order to pay. The amount is never accepted from the client: the server uses the order's own total.
const initializePaymentSchema = z.object({
  order_id: z
    .number({ error: 'Order id is required' })
    .int('Order id must be a whole number')
    .positive('Order id must be a positive number'),
});

module.exports = { initializePaymentSchema };
