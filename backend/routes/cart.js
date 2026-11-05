const express = require('express');
const validate = require('../middleware/validate');
const { validateId } = require('../middleware/validate');
const { authenticate, authorize } = require('../middleware/auth');
const { ROLES } = require('../utils/constants');
const { addItemSchema, updateItemSchema } = require('../utils/cartSchemas');
const cartController = require('../controllers/cartController');

const router = express.Router();

// The cart belongs to customers: every route needs a login AND the customer role.
router.use(authenticate, authorize(ROLES.CUSTOMER));

router.get('/', cartController.getCart);
router.post('/items', validate(addItemSchema), cartController.addItem);
router.put('/items/:id', validateId, validate(updateItemSchema), cartController.updateItem);
router.delete('/items/:id', validateId, cartController.removeItem);

module.exports = router;
