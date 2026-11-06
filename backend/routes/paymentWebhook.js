const express = require('express');
const paymentController = require('../controllers/paymentController');

const router = express.Router();

// express.raw keeps the body as untouched bytes so the signature can be checked (see app.js for why).
router.post('/', express.raw({ type: '*/*', limit: '200kb' }), paymentController.webhook);

module.exports = router;
