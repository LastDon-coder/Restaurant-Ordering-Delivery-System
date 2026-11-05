// An error we throw on purpose, with the HTTP status to answer with.
// Usage: throw new AppError('Food item not found', 404);
// The message of an AppError is safe to show to the client.
class AppError extends Error {
  // errors: optional list of { field, message } for form validation failures.
  constructor(message, statusCode = 500, errors = undefined) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;
    this.errors = errors;
  }
}

module.exports = AppError;
