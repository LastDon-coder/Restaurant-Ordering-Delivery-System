-- 013: password_reset_tokens  (added: the guide requires password reset but has no table for it)
-- Store only the SHA-256 hash of the token, never the token itself. The raw token goes in the
-- email link; if this table ever leaks, the hashes can't be used to reset anyone's password.
-- Tokens expire (expires_at) and are single-use (used_at is set once consumed).
CREATE TABLE password_reset_tokens (
  token_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED NOT NULL,
  token_hash CHAR(64)     NOT NULL COMMENT 'SHA-256 hex of the emailed token',
  expires_at DATETIME     NOT NULL,
  used_at    DATETIME     NULL DEFAULT NULL,
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (token_id),
  CONSTRAINT uq_password_reset_tokens_hash UNIQUE (token_hash),
  KEY idx_password_reset_tokens_user_id (user_id),
  CONSTRAINT fk_password_reset_tokens_user_id FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
