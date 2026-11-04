// An error we throw on purpose, with the HTTP status to answer with.
// Usage: throw new AppError('Food item not found', 404);
// The message of an AppError is safe to show to the client.
class AppError extends Error {
  constructor(message, statusCode = 500) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;
  }
}

module.exports = AppError;
