-- 014: order_status_history  (added for Step 13: records every status change and why)
-- orders.order_status only holds the CURRENT status. This table keeps the whole story: who moved the
-- order, from what to what, when, and the reason (required when rejecting, cancelling or failing).
-- from_status is NULL on the first row (the order being placed). changed_by is SET NULL if that
-- user is ever deleted, so the history survives. Rows go when their order goes (CASCADE).
CREATE TABLE order_status_history (
  history_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id    INT UNSIGNED NOT NULL,
  from_status ENUM('pending','confirmed','preparing','ready_for_delivery',
                   'out_for_delivery','delivered','cancelled','rejected','failed') NULL,
  to_status   ENUM('pending','confirmed','preparing','ready_for_delivery',
                   'out_for_delivery','delivered','cancelled','rejected','failed') NOT NULL,
  changed_by  INT UNSIGNED NULL,
  reason      VARCHAR(255) NULL,
  created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (history_id),
  KEY idx_status_history_order_created (order_id, created_at),
  KEY idx_status_history_changed_by (changed_by),
  CONSTRAINT fk_status_history_order_id FOREIGN KEY (order_id) REFERENCES orders (order_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_status_history_changed_by FOREIGN KEY (changed_by) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
