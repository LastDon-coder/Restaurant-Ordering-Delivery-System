-- 011: deliveries
-- Follows the guide: ORDERS 1 -> 1 DELIVERIES. UNIQUE (order_id) means an order has at most
-- one delivery row (it only gets one once a rider is assigned). Reassigning a rider updates
-- rider_id on that row. rider_id points to users.user_id (the user must have the rider role;
-- the backend checks that when assigning).
-- The (rider_id, delivery_status) index serves "my active deliveries" for a rider.
CREATE TABLE deliveries (
  delivery_id     INT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id        INT UNSIGNED NOT NULL,
  rider_id        INT UNSIGNED NOT NULL,
  delivery_status ENUM('assigned','picked_up','out_for_delivery','delivered','failed')
                  NOT NULL DEFAULT 'assigned',
  assigned_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  picked_up_at    TIMESTAMP    NULL DEFAULT NULL,
  delivered_at    TIMESTAMP    NULL DEFAULT NULL,
  PRIMARY KEY (delivery_id),
  CONSTRAINT uq_deliveries_order_id UNIQUE (order_id),
  KEY idx_deliveries_rider_status (rider_id, delivery_status),
  CONSTRAINT fk_deliveries_order_id FOREIGN KEY (order_id) REFERENCES orders (order_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_deliveries_rider_id FOREIGN KEY (rider_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
