-- 010: payments
-- Deviation from the guide (which says ORDERS 1 -> 1 PAYMENTS): there is NO unique key on
-- order_id. A failed card payment is retried, and each attempt is its own row with its own
-- reference. The latest row is the current one; "paid" means at least one row is 'paid'.
-- UNIQUE on transaction_reference stops the same provider reference being recorded twice
-- (this also makes webhook retries idempotent). MySQL allows many NULLs in a UNIQUE column,
-- which suits cash-on-delivery rows that have no reference yet.
CREATE TABLE payments (
  payment_id            INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  order_id              INT UNSIGNED  NOT NULL,
  payment_method        ENUM('online','cash_on_delivery','bank_transfer') NOT NULL,
  transaction_reference VARCHAR(100)  NULL,
  amount                DECIMAL(10,2) NOT NULL,
  payment_status        ENUM('pending','paid','failed','refunded') NOT NULL DEFAULT 'pending',
  paid_at               TIMESTAMP     NULL DEFAULT NULL,
  created_at            TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (payment_id),
  CONSTRAINT uq_payments_transaction_reference UNIQUE (transaction_reference),
  KEY idx_payments_order_id (order_id),
  KEY idx_payments_status (payment_status),
  CONSTRAINT fk_payments_order_id FOREIGN KEY (order_id) REFERENCES orders (order_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_payments_amount CHECK (amount >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
