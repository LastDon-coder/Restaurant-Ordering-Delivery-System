const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { corsOrigin } = require('./config/env');
const healthRoutes = require('./routes/health');
const authRoutes = require('./routes/auth');
const userRoutes = require('./routes/users');
const categoryRoutes = require('./routes/categories');
const foodRoutes = require('./routes/foods');
const cartRoutes = require('./routes/cart');
const orderRoutes = require('./routes/orders');
const paymentRoutes = require('./routes/payments');
const paymentWebhookRoutes = require('./routes/paymentWebhook');
const { notFound, errorHandler } = require('./middleware/errorHandler');

const app = express();

app.use(helmet()); // sets safe security headers
app.use(cors({ origin: corsOrigin })); // only the React app's origin may call the API
// The Paystack webhook is mounted BEFORE the JSON parser: its signature is computed over the exact raw
// bytes Paystack sent, and parsing then re-serialising the JSON would change them.
app.use('/api/v1/payments/webhook', paymentWebhookRoutes);
app.use(express.json({ limit: '10kb' })); // parse JSON bodies, reject oversized ones

app.use('/api/health', healthRoutes);
// Resource routes are versioned (/api/v1/...) as in the project guide.
// /api/health stays unversioned: it is for monitoring, not part of the API contract.
app.use('/api/v1/auth', authRoutes);
app.use('/api/v1/users', userRoutes);
app.use('/api/v1/categories', categoryRoutes);
app.use('/api/v1/foods', foodRoutes);
app.use('/api/v1/cart', cartRoutes);
app.use('/api/v1/orders', orderRoutes);
app.use('/api/v1/payments', paymentRoutes);

// Keep these two last: unmatched routes, then the central error handler.
app.use(notFound);
app.use(errorHandler);

module.exports = app;
