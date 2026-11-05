const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { jwt: jwtConfig } = require('../config/env');

// Login token. It only carries the user id ("sub"); the role is read from the database on each
// request (see middleware/auth.js), so a role change or deactivation takes effect immediately.
function signAccessToken(userId) {
  return jwt.sign({ sub: String(userId) }, jwtConfig.secret, {
    algorithm: 'HS256',
    expiresIn: jwtConfig.expiresIn,
  });
}

// Pinning the algorithm stops "alg: none" and algorithm-swap tricks.
function verifyAccessToken(token) {
  return jwt.verify(token, jwtConfig.secret, { algorithms: ['HS256'] });
}

// Password reset: the raw token goes in the emailed link, only its SHA-256 hash is stored.
function generateResetToken() {
  const token = crypto.randomBytes(32).toString('hex');
  return { token, tokenHash: hashResetToken(token) };
}

function hashResetToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

module.exports = { signAccessToken, verifyAccessToken, generateResetToken, hashResetToken };
