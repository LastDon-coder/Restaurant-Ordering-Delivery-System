-- 008: orders
-- Why copy the address into the order (delivery_* columns): if the customer later edits
-- or deletes a saved address, past orders must still show where they were delivered.
-- Why RESTRICT on user/address: order history must survive. Deactivate users, don't delete.
-- The status ENUM only restricts values. Valid transitions (pending -> confirmed ...) are
-- enforced in backend code, because SQL can't express "who may move it from A to B".
-- CHECKs make the money invariant impossible to break: total = subtotal + fee - discount.
CREATE TABLE orders (
  order_id                INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id                 INT UNSIGNED  NOT NULL,
  address_id              INT UNSIGNED  NOT NULL,
  order_status            ENUM('pending','confirmed','preparing','ready_for_delivery',
                               'out_for_delivery','delivered','cancelled','rejected','failed')
                          NOT NULL DEFAULT 'pending',
  subtotal                DECIMAL(10,2) NOT NULL,
  delivery_fee            DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  discount                DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  total_amount            DECIMAL(10,2) NOT NULL,
  delivery_street_address VARCHAR(255)  NOT NULL,
  delivery_city           VARCHAR(100)  NOT NULL,
  delivery_state          VARCHAR(100)  NOT NULL,
  delivery_landmark       VARCHAR(255)  NULL,
  created_at              TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (order_id),
  KEY idx_orders_user_created (user_id, created_at),
  KEY idx_orders_status (order_status),
  KEY idx_orders_address_id (address_id),
  CONSTRAINT fk_orders_user_id FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_orders_address_id FOREIGN KEY (address_id) REFERENCES addresses (address_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_orders_amounts CHECK (subtotal >= 0 AND delivery_fee >= 0 AND discount >= 0),
  CONSTRAINT chk_orders_total CHECK (total_amount = subtotal + delivery_fee - discount)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
