const express = require('express');
const validate = require('../middleware/validate');
const { validateId, validateQuery } = require('../middleware/validate');
const { authenticate, optionalAuthenticate, authorize } = require('../middleware/auth');
const { ROLES } = require('../utils/constants');
const { createFoodSchema, updateFoodSchema, listFoodsQuerySchema } = require('../utils/foodSchemas');
const foodController = require('../controllers/foodController');

const router = express.Router();

// Public: browse the menu (visitors see only foods on sale).
router.get('/', validateQuery(listFoodsQuerySchema), optionalAuthenticate, foodController.list);
router.get('/:id', validateId, optionalAuthenticate, foodController.getOne);

// Admin only: manage food items.
router.post('/', authenticate, authorize(ROLES.ADMIN), validate(createFoodSchema), foodController.create);
router.put(
  '/:id',
  validateId,
  authenticate,
  authorize(ROLES.ADMIN),
  validate(updateFoodSchema),
  foodController.update
);
router.delete('/:id', validateId, authenticate, authorize(ROLES.ADMIN), foodController.remove);

module.exports = router;
