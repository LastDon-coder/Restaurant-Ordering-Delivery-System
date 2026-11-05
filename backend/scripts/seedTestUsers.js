// Creates one test customer, one staff member and one rider, so you can try every role.
// Run: npm run seed:test-users
// All three get the password in TEST_USER_PASSWORD (.env). Safe to re-run: accounts that
// already exist are left alone.
// DEVELOPMENT ONLY: accounts with a shared, known password must never exist in production.
const { nodeEnv } = require('../config/env');
const pool = require('../config/db');
const { hashPassword } = require('../utils/password');
const userModel = require('../models/userModel');
const { ROLES } = require('../utils/constants');

const TEST_USERS = [
  { first_name: 'Test', last_name: 'Customer', email: 'customer@example.com', phone: '08011110001', roleName: ROLES.CUSTOMER },
  { first_name: 'Test', last_name: 'Staff', email: 'staff@example.com', phone: '08011110002', roleName: ROLES.STAFF },
  { first_name: 'Test', last_name: 'Rider', email: 'rider@example.com', phone: '08011110003', roleName: ROLES.RIDER },
];

async function main() {
  if (nodeEnv === 'production') {
    throw new Error('Refusing to create test users when NODE_ENV=production');
  }

  const { TEST_USER_PASSWORD } = process.env;
  if (!TEST_USER_PASSWORD) throw new Error('Set TEST_USER_PASSWORD in .env first');
  if (TEST_USER_PASSWORD.length < 10) throw new Error('TEST_USER_PASSWORD must be at least 10 characters');

  const passwordHash = await hashPassword(TEST_USER_PASSWORD);

  for (const { roleName, ...details } of TEST_USERS) {
    if (await userModel.findByEmail(details.email)) {
      console.log(`${roleName.padEnd(8)} ${details.email} already exists, nothing changed`);
      continue;
    }
    await userModel.create({ ...details, passwordHash, roleName });
    console.log(`${roleName.padEnd(8)} ${details.email} created`);
  }
}

main()
  .catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
