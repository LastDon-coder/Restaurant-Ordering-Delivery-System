const bcrypt = require('bcrypt');

// bcrypt cost factor: each +1 doubles the work. 12 is a sound default today.
const BCRYPT_ROUNDS = 12;

function hashPassword(plain) {
  return bcrypt.hash(plain, BCRYPT_ROUNDS);
}

function verifyPassword(plain, hash) {
  return bcrypt.compare(plain, hash);
}

// Used at login when the email doesn't exist, so that case takes as long as a real password
// check and the response time doesn't reveal which emails have accounts.
const DUMMY_HASH = bcrypt.hashSync('not-a-real-password', BCRYPT_ROUNDS);

module.exports = { hashPassword, verifyPassword, DUMMY_HASH };
