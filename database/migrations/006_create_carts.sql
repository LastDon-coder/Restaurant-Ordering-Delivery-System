-- 006: carts
-- UNIQUE (user_id) is what enforces "one cart per user" in the database itself,
-- so a bug or double-click in the app can't create two carts.
CREATE TABLE carts (
  cart_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED NOT NULL,
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (cart_id),
  CONSTRAINT uq_carts_user_id UNIQUE (user_id),
  CONSTRAINT fk_carts_user_id FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
