const { z } = require('zod');
const { CART_MAX_QUANTITY } = require('./constants');

// Input rules for the cart. The client sends only WHICH food and HOW MANY. Any price, total or
// user id it tries to send is dropped: the server looks those up itself.

const quantity = z
  .number({ error: 'Quantity must be a number' })
  .int('Quantity must be a whole number')
  .min(1, 'Quantity must be at least 1')
  .max(CART_MAX_QUANTITY, `Quantity must be at most ${CART_MAX_QUANTITY}`);

const addItemSchema = z.object({
  food_id: z
    .number({ error: 'Food id is required' })
    .int('Food id must be a whole number')
    .positive('Food id must be a positive number'),
  quantity: quantity.default(1),
});

// PUT sets the quantity to exactly this number (it does not add to the old one).
const updateItemSchema = z.object({ quantity: z.number({ error: 'Quantity is required' }).pipe(quantity) });

module.exports = { addItemSchema, updateItemSchema };
