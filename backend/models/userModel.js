const pool = require('../config/db');

// All SQL for the users table lives here. Every query uses ? placeholders (never string concatenation).
const PUBLIC_COLUMNS = `u.user_id, u.first_name, u.last_name, u.email, u.phone, u.is_active,
  r.role_name AS role`;

async function findById(userId) {
  const [rows] = await pool.execute(
    `SELECT ${PUBLIC_COLUMNS} FROM users u JOIN roles r ON r.role_id = u.role_id WHERE u.user_id = ?`,
    [userId]
  );
  return rows[0] || null;
}

// Includes the password hash: only for login. Never put the result in a response.
async function findByEmail(email) {
  const [rows] = await pool.execute(
    `SELECT ${PUBLIC_COLUMNS}, u.password FROM users u JOIN roles r ON r.role_id = u.role_id WHERE u.email = ?`,
    [email]
  );
  return rows[0] || null;
}

// The role is looked up by name inside the INSERT, so no code depends on role ids.
// A duplicate email throws ER_DUP_ENTRY (the UNIQUE key on users.email decides, not a racy pre-check).
async function create({ first_name, last_name, email, phone, passwordHash, roleName }) {
  const [result] = await pool.execute(
    `INSERT INTO users (first_name, last_name, email, phone, password, role_id)
     SELECT ?, ?, ?, ?, ?, role_id FROM roles WHERE role_name = ?`,
    [first_name, last_name, email, phone, passwordHash, roleName]
  );
  if (result.affectedRows === 0) {
    throw new Error(`Role "${roleName}" not found in the roles table`);
  }
  return result.insertId;
}

// What a client may see about a user: never the password hash.
function toPublicUser(user) {
  return {
    user_id: user.user_id,
    first_name: user.first_name,
    last_name: user.last_name,
    email: user.email,
    phone: user.phone,
    role: user.role,
  };
}

module.exports = { findById, findByEmail, create, toPublicUser };
