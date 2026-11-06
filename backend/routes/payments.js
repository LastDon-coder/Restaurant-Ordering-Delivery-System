const express = require('express');
const validate = require('../middleware/validate');
const { authenticate, authorize } = require('../middleware/auth');
const { paymentLimiter } = require('../middleware/rateLimiter');
const { ROLES } = require('../utils/constants');
const AppError = require('../utils/AppError');
const { initializePaymentSchema } = require('../utils/paymentSchemas');
const { REFERENCE_RE } = require('../services/paymentService');
const paymentController = require('../controllers/paymentController');

const router = express.Router();

function validateReference(req, res, next) {
  if (!REFERENCE_RE.test(req.params.reference)) throw new AppError('Invalid payment reference', 400);
  next();
}

router.use(paymentLimiter, authenticate);

router.post('/initialize', authorize(ROLES.CUSTOMER), validate(initializePaymentSchema), paymentController.initialize);
router.get('/verify/:reference', authorize(ROLES.CUSTOMER, ROLES.ADMIN, ROLES.STAFF), validateReference, paymentController.verify);

module.exports = router;
