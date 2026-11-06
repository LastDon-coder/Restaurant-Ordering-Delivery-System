const { z } = require('zod');
const { ORDER_STATUSES, PAYMENT_METHODS } = require('./constants');
const { optionalText } = require('./schemaHelpers');

const requiredText = (label, max) =>
  z
    .string({ error: `${label} is required` })
    .trim()
    .min(1, `${label} is required`)
    .max(max, `${label} must be at most ${max} characters`);

// Placing an order: WHERE to deliver and HOW to pay. What is ordered comes from the server-side
// cart, and prices/fees/totals are calculated by the server, so none of those are accepted here.
const placeOrderSchema = z.object({
  delivery_address: z.object(
    {
      street_address: requiredText('Street address', 255),
      city: requiredText('City', 100),
      state: requiredText('State', 100),
      landmark: optionalText('Landmark', 255),
    },
    { error: 'Delivery address is required' }
  ),
  payment_method: z.enum(PAYMENT_METHODS, { error: `Payment method must be one of: ${PAYMENT_METHODS.join(', ')}` }),
});

const blankToUndefined = (v) => (v === '' ? undefined : v);

const listOrdersQuerySchema = z.object({
  status: z.preprocess(blankToUndefined, z.enum(ORDER_STATUSES).optional()),
  page: z.preprocess(blankToUndefined, z.coerce.number().int().min(1).max(100000).default(1)),
  limit: z.preprocess(blankToUndefined, z.coerce.number().int().min(1).max(100).default(20)),
});

module.exports = { placeOrderSchema, listOrdersQuerySchema };
