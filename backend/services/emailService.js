const { nodeEnv } = require('../config/env');

// Placeholder for real email. For now the reset link is printed in the server terminal
// (development only) so you can test the flow without an email account.
// TODO (later step): send a real email here, e.g. with Nodemailer. Until then, password reset
// does not work in production, because nothing delivers the link.
async function sendPasswordResetEmail(user, resetLink) {
  if (nodeEnv !== 'production') {
    console.log(`[DEV] Password reset link for ${user.email}: ${resetLink}`);
  }
}

module.exports = { sendPasswordResetEmail };
