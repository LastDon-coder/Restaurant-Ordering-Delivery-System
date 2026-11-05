const AppError = require('../utils/AppError');

// Checks req.body against a zod schema before the controller runs.
// On success req.body is replaced with the cleaned data (trimmed, lowercased, unknown fields removed).
// On failure the client gets 400 with a list of { field, message }.
function validate(schema) {
  return (req, res, next) => {
    const result = schema.safeParse(req.body);
    if (!result.success) {
      const errors = result.error.issues.map((issue) => ({
        field: issue.path.join('.'),
        message: issue.message,
      }));
      throw new AppError('Validation failed', 400, errors);
    }
    req.body = result.data;
    next();
  };
}

// Checks that the :id in the URL is a positive whole number before it reaches the database.
function validateId(req, res, next) {
  if (!/^[1-9]\d{0,9}$/.test(req.params.id)) {
    throw new AppError('Invalid id', 400);
  }
  next();
}

module.exports = validate;
module.exports.validateId = validateId;
