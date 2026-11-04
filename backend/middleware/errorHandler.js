const AppError = require('../utils/AppError');

// Runs when no route matched.
function notFound(req, res, next) {
  next(new AppError(`Route not found: ${req.method} ${req.originalUrl}`, 404));
}

// Every error in the app ends up here and leaves in the same shape:
// { success: false, message }
// (Express 5 sends rejected promises from async handlers here automatically.)
function errorHandler(err, req, res, next) { // eslint-disable-line no-unused-vars
  let status = err.statusCode || err.status || 500;
  let message = err.message;

  if (err.type === 'entity.parse.failed') {
    status = 400;
    message = 'Invalid JSON in request body';
  } else if (err.type === 'entity.too.large') {
    status = 413;
    message = 'Request body too large';
  } else if (err.code === 'ER_DUP_ENTRY') {
    // A UNIQUE key was violated, e.g. registering an email that already exists.
    status = 409;
    message = 'A record with this value already exists';
  }

  if (status >= 500) {
    console.error(err); // full detail stays in the server log
    // Unexpected errors can contain SQL or file paths, so never send them to the client.
    if (!err.isOperational) message = 'Internal server error';
  }

  res.status(status).json({ success: false, message });
}

module.exports = { notFound, errorHandler };
