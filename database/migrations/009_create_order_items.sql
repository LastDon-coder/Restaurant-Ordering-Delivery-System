-- 009: order_items
-- price and food_name are SNAPSHOTS taken at order time. If the menu price or name changes
-- tomorrow, this order must still show what the customer actually bought and paid.
-- subtotal is a STORED generated column: the database computes quantity * price itself,
-- so it can never disagree with the other two columns.
-- RESTRICT on food_id: a food that appears in past orders can't be deleted
-- (set is_available = 0 instead). CASCADE on order_id: items belong to their order.
CREATE TABLE order_items (
  order_item_id INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  order_id      INT UNSIGNED  NOT NULL,
  food_id       INT UNSIGNED  NOT NULL,
  food_name     VARCHAR(150)  NOT NULL,
  quantity      INT UNSIGNED  NOT NULL,
  price         DECIMAL(10,2) NOT NULL,
  subtotal      DECIMAL(10,2) GENERATED ALWAYS AS (quantity * price) STORED,
  PRIMARY KEY (order_item_id),
  KEY idx_order_items_order_id (order_id),
  KEY idx_order_items_food_id (food_id),
  CONSTRAINT fk_order_items_order_id FOREIGN KEY (order_id) REFERENCES orders (order_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_order_items_food_id FOREIGN KEY (food_id) REFERENCES food_items (food_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_order_items_quantity CHECK (quantity > 0),
  CONSTRAINT chk_order_items_price CHECK (price >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
