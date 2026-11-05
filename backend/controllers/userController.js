const AppError = require('../utils/AppError');
const { sendSuccess } = require('../utils/response');
const { hashPassword } = require('../utils/password');
const userModel = require('../models/userModel');

// POST /api/users (admin only): create a staff or rider account.
// The admin chooses the role (the validation schema only allows staff or rider).
async function createUser(req, res) {
  const { first_name, last_name, email, phone, password, role } = req.body;
  const passwordHash = await hashPassword(password);

  let userId;
  try {
    userId = await userModel.create({ first_name, last_name, email, phone, passwordHash, roleName: role });
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') throw new AppError('An account with this email already exists', 409);
    throw err;
  }

  const user = await userModel.findById(userId);
  sendSuccess(res, 201, `${role} account created`, { user: userModel.toPublicUser(user) });
}

module.exports = { createUser };
