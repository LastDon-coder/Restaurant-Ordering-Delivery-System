const AppError = require('../utils/AppError');
const { sendSuccess } = require('../utils/response');
const { CART_MAX_QUANTITY } = require('../utils/constants');
const cartModel = require('../models/cartModel');
const foodModel = require('../models/foodModel');
const { buildCart } = require('../services/cartService');

// Every cart endpoint answers with the whole, freshly calculated cart, so the React app can
// simply replace what it shows. req.user.user_id comes from the login token, never from the request.
async function sendCart(res, status, message, userId) {
  const cart = buildCart(await cartModel.findItems(userId));
  sendSuccess(res, status, message, { cart });
}

// GET /api/v1/cart
async function getCart(req, res) {
  await sendCart(res, 200, 'Cart retrieved', req.user.user_id);
}

// POST /api/v1/cart/items   { food_id, quantity }
// Adding a food that is already in the cart increases its quantity.
async function addItem(req, res) {
  const { food_id, quantity } = req.body;

  // Same rule as the public menu: only foods on sale, in active categories.
  const food = await foodModel.findById(food_id);
  if (!food || !food.is_available || food.category_status !== 'active') {
    throw new AppError('Food item not found or currently unavailable', 404);
  }

  const added = await cartModel.addItem(req.user.user_id, food_id, quantity);
  if (!added) {
    throw new AppError('Validation failed', 400, [
      { field: 'quantity', message: `You can have at most ${CART_MAX_QUANTITY} of one item in your cart` },
    ]);
  }
  await sendCart(res, 201, 'Item added to cart', req.user.user_id);
}

// PUT /api/v1/cart/items/:id   { quantity }   (sets the quantity to exactly this number)
async function updateItem(req, res) {
  const item = await cartModel.findItem(req.user.user_id, req.params.id);
  if (!item) throw new AppError('Cart item not found', 404);

  await cartModel.setQuantity(item.cart_item_id, req.body.quantity);
  await sendCart(res, 200, 'Cart item updated', req.user.user_id);
}

// DELETE /api/v1/cart/items/:id
async function removeItem(req, res) {
  const item = await cartModel.findItem(req.user.user_id, req.params.id);
  if (!item) throw new AppError('Cart item not found', 404);

  await cartModel.removeItem(item.cart_item_id);
  await sendCart(res, 200, 'Item removed from cart', req.user.user_id);
}

module.exports = { getCart, addItem, updateItem, removeItem };
