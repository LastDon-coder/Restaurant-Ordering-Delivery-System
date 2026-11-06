const { rateLimit } = require('express-rate-limit');

// Brute-force protection. Counts are per IP address and kept in memory, so they reset when the
// server restarts (fine for one server; use a shared store such as Redis if you ever run several).
const tooMany = { success: false, message: 'Too many attempts. Please try again later.' };

const common = {
  windowMs: 15 * 60 * 1000, // 15 minutes
  standardHeaders: 'draft-7', // tells the client how long to wait (RateLimit headers)
  legacyHeaders: false,
  message: tooMany,
};

// Login: only FAILED attempts count, so real users aren't locked out for logging in a lot.
const loginLimiter = rateLimit({ ...common, limit: 10, skipSuccessfulRequests: true });

// Register, forgot-password, reset-password.
const authLimiter = rateLimit({ ...common, limit: 20 });

// Payment start/verify call Paystack on every request, so cap them per IP (120 a minute is far more than a real customer needs).
const paymentLimiter = rateLimit({ ...common, windowMs: 60 * 1000, limit: 120 });

module.exports = { loginLimiter, authLimiter, paymentLimiter };
