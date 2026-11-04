-- 005: addresses (a customer can save several delivery addresses)
-- CASCADE: if a user is ever removed, their saved addresses go with them.
-- (Orders keep their own copy of the address, see 008_create_orders.sql.)
CREATE TABLE addresses (
  address_id     INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id        INT UNSIGNED NOT NULL,
  street_address VARCHAR(255) NOT NULL,
  city           VARCHAR(100) NOT NULL,
  state          VARCHAR(100) NOT NULL,
  landmark       VARCHAR(255) NULL,
  created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (address_id),
  KEY idx_addresses_user_id (user_id),
  CONSTRAINT fk_addresses_user_id FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
