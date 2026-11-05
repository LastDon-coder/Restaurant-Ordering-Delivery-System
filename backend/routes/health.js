const express = require('express');
const pool = require('../config/db');
const AppError = require('../utils/AppError');

const router = express.Router();

// GET /api/health: confirms the API is up and can reach MySQL.
router.get('/', async (req, res) => {
  try {
    await pool.query('SELECT 1');
  } catch (err) {
    console.error('Health check failed:', [err.code, err.message].filter(Boolean).join(' - '));
    throw new AppError('Database unavailable', 503);
  }
  res.json({ success: true, message: 'API and database are healthy', data: null });
});

module.exports = router;
