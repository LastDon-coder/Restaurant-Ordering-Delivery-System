const express = require('express');
const validate = require('../middleware/validate');
const { validateId } = require('../middleware/validate');
const { authenticate, optionalAuthenticate, authorize } = require('../middleware/auth');
const { ROLES } = require('../utils/constants');
const { createCategorySchema, updateCategorySchema } = require('../utils/categorySchemas');
const categoryController = require('../controllers/categoryController');

const router = express.Router();

// Public: browse categories (visitors see active ones only).
router.get('/', optionalAuthenticate, categoryController.list);
router.get('/:id', validateId, optionalAuthenticate, categoryController.getOne);

// Admin only: manage categories.
router.post('/', authenticate, authorize(ROLES.ADMIN), validate(createCategorySchema), categoryController.create);
router.put(
  '/:id',
  validateId,
  authenticate,
  authorize(ROLES.ADMIN),
  validate(updateCategorySchema),
  categoryController.update
);
router.delete('/:id', validateId, authenticate, authorize(ROLES.ADMIN), categoryController.remove);

module.exports = router;
