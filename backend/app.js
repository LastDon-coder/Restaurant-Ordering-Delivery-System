const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { corsOrigin } = require('./config/env');
const healthRoutes = require('./routes/health');
const { notFound, errorHandler } = require('./middleware/errorHandler');

const app = express();

app.use(helmet()); // sets safe security headers
app.use(cors({ origin: corsOrigin })); // only the React app's origin may call the API
app.use(express.json({ limit: '10kb' })); // parse JSON bodies, reject oversized ones

app.use('/api/health', healthRoutes);

// Keep these two last: unmatched routes, then the central error handler.
app.use(notFound);
app.use(errorHandler);

module.exports = app;
