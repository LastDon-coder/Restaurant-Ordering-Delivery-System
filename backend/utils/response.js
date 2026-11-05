// Every successful response has the same shape: { success, message, data }.
// (Errors use the same keys, minus data: see middleware/errorHandler.js.)
function sendSuccess(res, status, message, data = null) {
  return res.status(status).json({ success: true, message, data });
}

module.exports = { sendSuccess };
