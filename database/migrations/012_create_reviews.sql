-- 012: reviews
-- UNIQUE (user_id, food_id): one review per customer per food.
-- CHECK keeps ratings between 1 and 5.
-- (Later, in the backend, only allow reviews from customers who actually ordered that food.)
CREATE TABLE reviews (
  review_id  INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED     NOT NULL,
  food_id    INT UNSIGNED     NOT NULL,
  rating     TINYINT UNSIGNED NOT NULL,
  comment    VARCHAR(1000)    NULL,
  created_at TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (review_id),
  CONSTRAINT uq_reviews_user_food UNIQUE (user_id, food_id),
  KEY idx_reviews_food_id (food_id),
  CONSTRAINT fk_reviews_user_id FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_reviews_food_id FOREIGN KEY (food_id) REFERENCES food_items (food_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT chk_reviews_rating CHECK (rating BETWEEN 1 AND 5)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
