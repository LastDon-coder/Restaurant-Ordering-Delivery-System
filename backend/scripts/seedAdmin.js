// Creates the first admin account from ADMIN_EMAIL / ADMIN_PASSWORD / ADMIN_PHONE in .env.
// Run once after the database is set up: npm run seed:admin
// Safe to re-run: if the email already exists it changes nothing.
require('../config/env');
const bcrypt = require('bcrypt');
const pool = require('../config/db');

async function main() {
  const { ADMIN_EMAIL, ADMIN_PASSWORD, ADMIN_PHONE } = process.env;
  if (!ADMIN_EMAIL || !ADMIN_PASSWORD || !ADMIN_PHONE) {
    throw new Error('Set ADMIN_EMAIL, ADMIN_PASSWORD and ADMIN_PHONE in .env first');
  }
  if (ADMIN_PASSWORD.length < 10) {
    throw new Error('ADMIN_PASSWORD must be at least 10 characters');
  }

  const [roles] = await pool.execute('SELECT role_id FROM roles WHERE role_name = ?', ['admin']);
  if (roles.length === 0) {
    throw new Error('Admin role not found. Run database/seeds/001_seed_roles.sql first');
  }

  const [existing] = await pool.execute('SELECT user_id FROM users WHERE email = ?', [ADMIN_EMAIL]);
  if (existing.length > 0) {
    console.log(`Admin ${ADMIN_EMAIL} already exists, nothing changed`);
    return;
  }

  // 12 is the bcrypt cost factor: higher is slower to brute-force, and also slower to log in.
  const passwordHash = await bcrypt.hash(ADMIN_PASSWORD, 12);
  await pool.execute(
    'INSERT INTO users (first_name, last_name, email, phone, password, role_id) VALUES (?, ?, ?, ?, ?, ?)',
    ['Restaurant', 'Admin', ADMIN_EMAIL, ADMIN_PHONE, passwordHash, roles[0].role_id]
  );
  console.log(`Admin created: ${ADMIN_EMAIL}`);
}

main()
  .catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
