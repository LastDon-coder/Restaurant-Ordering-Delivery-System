-- 015: payment_refunds  (added for refunds: the guide's payments table has no place to track them)
-- One row per Paystack transaction that we asked to refund. A refund is not instant: Paystack queues it
-- and tells us later by webhook, so we track it: pending -> processed (money is on its way back) or failed.
-- transaction_reference is UNIQUE: the same payment can never be refunded twice (a double click, a retry).
-- It is the reference of the payment being refunded, which is usually payments.transaction_reference but
-- can also be a duplicate payment (the customer paid twice) that never got recorded on the payment row.
-- requested_by is SET NULL if that admin is ever deleted, so the record survives.
CREATE TABLE payment_refunds (
  refund_id             INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  payment_id            INT UNSIGNED  NOT NULL,
  transaction_reference VARCHAR(100)  NOT NULL,
  amount                DECIMAL(10,2) NOT NULL,
  refund_status         ENUM('pending','processed','failed') NOT NULL DEFAULT 'pending',
  paystack_refund_id    VARCHAR(50)   NULL,
  reason                VARCHAR(255)  NOT NULL,
  requested_by          INT UNSIGNED  NULL,
  created_at            TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (refund_id),
  CONSTRAINT uq_payment_refunds_reference UNIQUE (transaction_reference),
  KEY idx_payment_refunds_payment_id (payment_id),
  KEY idx_payment_refunds_requested_by (requested_by),
  CONSTRAINT fk_payment_refunds_payment_id FOREIGN KEY (payment_id) REFERENCES payments (payment_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_payment_refunds_requested_by FOREIGN KEY (requested_by) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT chk_payment_refunds_amount CHECK (amount > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
