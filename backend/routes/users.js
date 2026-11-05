const express = require('express');
const validate = require('../middleware/validate');
const { authenticate, authorize } = require('../middleware/auth');
const { ROLES } = require('../utils/constants');
const { createUserSchema } = require('../utils/authSchemas');
const userController = require('../controllers/userController');

const router = express.Router();

// Admin only: create staff and rider accounts.
router.post('/', authenticate, authorize(ROLES.ADMIN), validate(createUserSchema), userController.createUser);

module.exports = router;
