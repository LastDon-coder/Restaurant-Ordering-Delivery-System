const pool = require('../config/db');

// Expiry is computed by MySQL (NOW() + 1 hour) and compared by MySQL, so the app server's
// clock and time zone can never disagree with the database's.
async function replaceToken(userId, tokenHash) {
  // A user keeps only one live reset link: asking again invalidates the previous one.
  await pool.execute('DELETE FROM password_reset_tokens WHERE user_id = ? AND used_at IS NULL', [userId]);
  await pool.execute(
    `INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
     VALUES (?, ?, DATE_ADD(NOW(), INTERVAL 1 HOUR))`,
    [userId, tokenHash]
  );
}

// Returns true if the token was valid and the password was changed, false otherwise.
// Transaction: the password change and "mark token used" succeed or fail together, and
// FOR UPDATE locks the token row so two simultaneous requests can't both use it.
async function resetPasswordWithToken(tokenHash, passwordHash) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [rows] = await conn.execute(
      `SELECT t.user_id
       FROM password_reset_tokens t JOIN users u ON u.user_id = t.user_id
       WHERE t.token_hash = ? AND t.used_at IS NULL AND t.expires_at > NOW() AND u.is_active = 1
       FOR UPDATE`,
      [tokenHash]
    );
    if (rows.length === 0) {
      await conn.rollback();
      return false;
    }

    const userId = rows[0].user_id;
    await conn.execute('UPDATE users SET password = ? WHERE user_id = ?', [passwordHash, userId]);
    await conn.execute(
      'UPDATE password_reset_tokens SET used_at = NOW() WHERE user_id = ? AND used_at IS NULL',
      [userId]
    );

    await conn.commit();
    return true;
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }
}

module.exports = { replaceToken, resetPasswordWithToken };
