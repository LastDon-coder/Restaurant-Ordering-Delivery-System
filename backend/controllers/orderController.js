const AppError = require('../utils/AppError');
const { sendSuccess } = require('../utils/response');
const { ROLES } = require('../utils/constants');
const orderModel = require('../models/orderModel');
const { placeOrder } = require('../services/orderService');

// POST /api/v1/orders   (customer)
async function createOrder(req, res) {
  const orderId = await placeOrder(req.user.user_id, req.body);
  const order = await orderModel.findById(orderId);
  sendSuccess(res, 201, 'Order placed', { order });
}

// GET /api/v1/orders   customers see their own orders; admin and staff see everyone's
async function listOrders(req, res) {
  const { status, page, limit } = req.validatedQuery;
  const userId = req.user.role === ROLES.CUSTOMER ? req.user.user_id : undefined;
  const { orders, total } = await orderModel.list({ userId, status, page, limit });
  sendSuccess(res, 200, 'Orders retrieved', {
    orders,
    pagination: { page, limit, total, total_pages: Math.ceil(total / limit) },
  });
}

// GET /api/v1/orders/:id
async function getOrder(req, res) {
  const order = await orderModel.findById(Number(req.params.id));
  // Someone else's order looks exactly like a missing one (404), so ids can't be probed.
  if (!order || (req.user.role === ROLES.CUSTOMER && order.customer.user_id !== req.user.user_id)) {
    throw new AppError('Order not found', 404);
  }
  sendSuccess(res, 200, 'Order retrieved', { order });
}

module.exports = { createOrder, listOrders, getOrder };
