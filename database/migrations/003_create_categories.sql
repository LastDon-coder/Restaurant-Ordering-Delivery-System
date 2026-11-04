-- 003: categories
CREATE TABLE categories (
  category_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  category_name VARCHAR(100) NOT NULL,
  description   VARCHAR(255) NULL,
  image_url     VARCHAR(500) NULL,
  status        ENUM('active','inactive') NOT NULL DEFAULT 'active',
  PRIMARY KEY (category_id),
  CONSTRAINT uq_categories_category_name UNIQUE (category_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
