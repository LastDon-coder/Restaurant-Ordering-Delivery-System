const express = require('express');
const validate = require('../middleware/validate');
const { validateId, validateQuery } = require('../middleware/validate');
const { authenticate, authorize } = require('../middleware/auth');
const { ROLES } = require('../utils/constants');
const { placeOrderSchema, listOrdersQuerySchema } = require('../utils/orderSchemas');
const orderController = require('../controllers/orderController');

const router = express.Router();

router.use(authenticate);

// Only customers place orders. Riders get order access in Step 15, once deliveries exist.
router.post('/', authorize(ROLES.CUSTOMER), validate(placeOrderSchema), orderController.createOrder);
router.get('/', authorize(ROLES.CUSTOMER, ROLES.ADMIN, ROLES.STAFF), validateQuery(listOrdersQuerySchema), orderController.listOrders);
router.get('/:id', authorize(ROLES.CUSTOMER, ROLES.ADMIN, ROLES.STAFF), validateId, orderController.getOrder);

module.exports = router;
