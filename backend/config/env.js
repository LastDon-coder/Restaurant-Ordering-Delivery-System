// Loads .env once and exports validated settings.
// Failing here, at startup, is better than failing later in the middle of a request.
require('dotenv').config({ quiet: true });

const required = ['DB_HOST', 'DB_USER', 'DB_NAME'];
const missing = required.filter((name) => !process.env[name]);
if (missing.length > 0) {
  console.error(`Missing required environment variables: ${missing.join(', ')}`);
  console.error('Copy .env.example to .env and fill them in.');
  process.exit(1);
}

// The JWT secret signs every login token. If it is short or guessable, anyone can forge a token
// (including an admin one), so refuse to start without a long random value.
const jwtSecret = process.env.JWT_SECRET || '';
if (jwtSecret.length < 32) {
  console.error('JWT_SECRET is missing or shorter than 32 characters.');
  console.error('Generate one with: node -e "console.log(require(\'crypto\').randomBytes(48).toString(\'hex\'))"');
  process.exit(1);
}

const corsOrigin = process.env.CORS_ORIGIN || 'http://localhost:5173';

module.exports = {
  nodeEnv: process.env.NODE_ENV || 'development',
  port: Number(process.env.PORT) || 5000,
  corsOrigin,
  // Where the React app lives; used to build the password reset link.
  frontendUrl: process.env.FRONTEND_URL || corsOrigin,
  jwt: {
    secret: jwtSecret,
    expiresIn: process.env.JWT_EXPIRES_IN || '1d',
  },
  db: {
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT) || 3306,
    user: process.env.DB_USER,
    // Empty is allowed: a local MySQL root user often has no password.
    password: process.env.DB_PASSWORD || '',
    database: process.env.DB_NAME,
  },
};
