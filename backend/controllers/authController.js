const AppError = require('../utils/AppError');
const { sendSuccess } = require('../utils/response');
const { ROLES } = require('../utils/constants');
const { hashPassword, verifyPassword, DUMMY_HASH } = require('../utils/password');
const { signAccessToken, generateResetToken, hashResetToken } = require('../utils/token');
const { frontendUrl } = require('../config/env');
const userModel = require('../models/userModel');
const passwordResetModel = require('../models/passwordResetModel');
const emailService = require('../services/emailService');

// POST /api/auth/register: public sign-up. Always creates a CUSTOMER; the role is never
// taken from the request, so nobody can register themselves as admin.
async function register(req, res) {
  const { first_name, last_name, email, phone, password } = req.body;
  const passwordHash = await hashPassword(password);

  let userId;
  try {
    userId = await userModel.create({
      first_name,
      last_name,
      email,
      phone,
      passwordHash,
      roleName: ROLES.CUSTOMER,
    });
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') throw new AppError('An account with this email already exists', 409);
    throw err;
  }

  const user = await userModel.findById(userId);
  sendSuccess(res, 201, 'Account created', {
    user: userModel.toPublicUser(user),
    token: signAccessToken(userId),
  });
}

// POST /api/auth/login
async function login(req, res) {
  const { email, password } = req.body;

  const user = await userModel.findByEmail(email);
  // Compare against a dummy hash when the email is unknown, so timing doesn't reveal which emails exist.
  const passwordOk = await verifyPassword(password, user ? user.password : DUMMY_HASH);
  if (!user || !passwordOk) throw new AppError('Invalid email or password', 401);
  if (!user.is_active) throw new AppError('This account has been deactivated', 403);

  sendSuccess(res, 200, 'Login successful', {
    user: userModel.toPublicUser(user),
    token: signAccessToken(user.user_id),
  });
}

// GET /api/auth/me: who am I? (req.user was set by the authenticate middleware)
async function me(req, res) {
  sendSuccess(res, 200, 'Current user', { user: userModel.toPublicUser(req.user) });
}

// POST /api/auth/forgot-password
// Always answers the same way, whether or not the email has an account, so this endpoint
// can't be used to find out who is registered.
async function forgotPassword(req, res) {
  const user = await userModel.findByEmail(req.body.email);

  if (user && user.is_active) {
    const { token, tokenHash } = generateResetToken();
    await passwordResetModel.replaceToken(user.user_id, tokenHash);
    await emailService.sendPasswordResetEmail(user, `${frontendUrl}/reset-password?token=${token}`);
  }

  sendSuccess(res, 200, 'If an account with that email exists, a password reset link has been sent');
}

// POST /api/auth/reset-password
async function resetPassword(req, res) {
  const { token, password } = req.body;
  const passwordHash = await hashPassword(password);

  const changed = await passwordResetModel.resetPasswordWithToken(hashResetToken(token), passwordHash);
  if (!changed) throw new AppError('Invalid or expired reset token', 400);

  sendSuccess(res, 200, 'Password has been reset. You can now log in');
}

module.exports = { register, login, me, forgotPassword, resetPassword };
