-- 004: food_items
-- Why DECIMAL(10,2): money must never be FLOAT/DOUBLE (0.1 + 0.2 != 0.3 in floating point).
-- Why RESTRICT on category: you can't delete a category that still has food in it.
-- The composite index (category_id, is_available) serves the menu query
-- "show available foods in this category".
CREATE TABLE food_items (
  food_id      INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  category_id  INT UNSIGNED  NOT NULL,
  food_name    VARCHAR(150)  NOT NULL,
  description  TEXT          NULL,
  price        DECIMAL(10,2) NOT NULL,
  image_url    VARCHAR(500)  NULL,
  is_available TINYINT(1)    NOT NULL DEFAULT 1,
  created_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (food_id),
  KEY idx_food_items_category_available (category_id, is_available),
  CONSTRAINT fk_food_items_category_id FOREIGN KEY (category_id) REFERENCES categories (category_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_food_items_price CHECK (price >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
