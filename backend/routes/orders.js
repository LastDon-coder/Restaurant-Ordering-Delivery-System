const express = require('express');
const validate = require('../middleware/validate');
const { validateId, validateQuery } = require('../middleware/validate');
const { authenticate, authorize } = require('../middleware/auth');
const { ROLES } = require('../utils/constants');
const { placeOrderSchema, listOrdersQuerySchema, updateStatusSchema } = require('../utils/orderSchemas');
const orderController = require('../controllers/orderController');

const router = express.Router();

router.use(authenticate);

// Only customers place orders. Riders get order access in Step 15, once deliveries exist.
router.post('/', authorize(ROLES.CUSTOMER), validate(placeOrderSchema), orderController.createOrder);
router.get('/', authorize(ROLES.CUSTOMER, ROLES.ADMIN, ROLES.STAFF), validateQuery(listOrdersQuerySchema), orderController.listOrders);
router.get('/:id', authorize(ROLES.CUSTOMER, ROLES.ADMIN, ROLES.STAFF), validateId, orderController.getOrder);
// Staff/admin move orders along. Customers may only cancel their own pending order (checked in the service).
router.patch('/:id/status', authorize(ROLES.CUSTOMER, ROLES.ADMIN, ROLES.STAFF), validateId, validate(updateStatusSchema), orderController.updateStatus);

module.exports = router;
