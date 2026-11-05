const AppError = require('../utils/AppError');
const { verifyAccessToken } = require('../utils/token');
const userModel = require('../models/userModel');

// Authentication: "who are you?" Reads "Authorization: Bearer <token>", checks the signature
// and expiry, then loads the user from the database. Loading every time (instead of trusting
// the token's contents) means a deactivated user or a changed role takes effect immediately.
async function authenticate(req, res, next) {
  const [scheme, token] = (req.headers.authorization || '').split(' ');
  if (!scheme || scheme.toLowerCase() !== 'bearer' || !token) {
    throw new AppError('Authentication required', 401);
  }

  let payload;
  try {
    payload = verifyAccessToken(token);
  } catch (err) {
    // Same message for expired, tampered and malformed tokens: don't help an attacker tell them apart.
    throw new AppError('Invalid or expired token', 401);
  }

  if (!/^\d+$/.test(String(payload.sub))) throw new AppError('Invalid or expired token', 401);

  const user = await userModel.findById(payload.sub);
  if (!user || !user.is_active) throw new AppError('Invalid or expired token', 401);

  req.user = user;
  next();
}

// Authorization: "are you allowed?" Use after authenticate:
//   router.post('/', authenticate, authorize('admin'), handler)
function authorize(...allowedRoles) {
  return (req, res, next) => {
    if (!req.user) throw new AppError('Authentication required', 401);
    if (!allowedRoles.includes(req.user.role)) {
      throw new AppError('You do not have permission to do this', 403);
    }
    next();
  };
}

module.exports = { authenticate, authorize };
