-- 007: cart_items
-- UNIQUE (cart_id, food_id): the same food appears once per cart; adding it again
-- means "increase quantity" (INSERT ... ON DUPLICATE KEY UPDATE), not a second row.
-- The price column comes from the guide, but treat it as a display hint only.
-- At checkout the server re-reads food_items.price, never this value.
CREATE TABLE cart_items (
  cart_item_id INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  cart_id      INT UNSIGNED  NOT NULL,
  food_id      INT UNSIGNED  NOT NULL,
  quantity     INT UNSIGNED  NOT NULL DEFAULT 1,
  price        DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (cart_item_id),
  CONSTRAINT uq_cart_items_cart_food UNIQUE (cart_id, food_id),
  KEY idx_cart_items_food_id (food_id),
  CONSTRAINT fk_cart_items_cart_id FOREIGN KEY (cart_id) REFERENCES carts (cart_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_cart_items_food_id FOREIGN KEY (food_id) REFERENCES food_items (food_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT chk_cart_items_quantity CHECK (quantity > 0),
  CONSTRAINT chk_cart_items_price CHECK (price >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
