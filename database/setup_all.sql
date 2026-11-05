-- setup_all.sql: builds the whole database in one run (all migrations, then seed data).
-- It is the files in migrations/ and seeds/ joined together, in order. Those files are the
-- source of truth; if one changes, regenerate this file.
-- Run it in a MySQL Workbench query tab (File > Open SQL Script, then the lightning bolt).
-- If restaurant_db already exists from a partial run, first run: DROP DATABASE restaurant_db;

-- ===== migrations/000_create_database.sql =====
-- 000: create the database
-- utf8mb4 stores every character (emoji, accents); the unicode_ci collation
-- gives case-insensitive comparisons, which is what you want for emails/names.
CREATE DATABASE IF NOT EXISTS restaurant_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE restaurant_db;

-- ===== migrations/001_create_roles.sql =====
-- 001: roles
-- A lookup table instead of an ENUM: adding a role later is an INSERT,
-- not an ALTER TABLE on a big users table.
CREATE TABLE roles (
  role_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  role_name VARCHAR(30)  NOT NULL,
  PRIMARY KEY (role_id),
  CONSTRAINT uq_roles_role_name UNIQUE (role_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ===== migrations/002_create_users.sql =====
-- 002: users (customers, admins, staff and riders all live here; role_id tells them apart)
-- Why: one table means one login flow. The role decides what each person may do.
-- is_active lets you disable an account without deleting it, so old orders keep their owner.
CREATE TABLE users (
  user_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  first_name VARCHAR(100) NOT NULL,
  last_name  VARCHAR(100) NOT NULL,
  email      VARCHAR(255) NOT NULL,
  phone      VARCHAR(20)  NOT NULL,
  password   VARCHAR(255) NOT NULL COMMENT 'bcrypt hash only, never plain text',
  role_id    INT UNSIGNED NOT NULL,
  is_active  TINYINT(1)   NOT NULL DEFAULT 1,
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id),
  CONSTRAINT uq_users_email UNIQUE (email),
  KEY idx_users_role_id (role_id),
  CONSTRAINT fk_users_role_id FOREIGN KEY (role_id) REFERENCES roles (role_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ===== migrations/003_create_categories.sql =====
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

-- ===== migrations/004_create_food_items.sql =====
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

-- ===== migrations/005_create_addresses.sql =====
-- 005: addresses (a customer can save several delivery addresses)
-- CASCADE: if a user is ever removed, their saved addresses go with them.
-- (Orders keep their own copy of the address, see 008_create_orders.sql.)
CREATE TABLE addresses (
  address_id     INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id        INT UNSIGNED NOT NULL,
  street_address VARCHAR(255) NOT NULL,
  city           VARCHAR(100) NOT NULL,
  state          VARCHAR(100) NOT NULL,
  landmark       VARCHAR(255) NULL,
  created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (address_id),
  KEY idx_addresses_user_id (user_id),
  CONSTRAINT fk_addresses_user_id FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ===== migrations/006_create_carts.sql =====
-- 006: carts
-- UNIQUE (user_id) is what enforces "one cart per user" in the database itself,
-- so a bug or double-click in the app can't create two carts.
CREATE TABLE carts (
  cart_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED NOT NULL,
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (cart_id),
  CONSTRAINT uq_carts_user_id UNIQUE (user_id),
  CONSTRAINT fk_carts_user_id FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ===== migrations/007_create_cart_items.sql =====
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

-- ===== migrations/008_create_orders.sql =====
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

-- ===== migrations/009_create_order_items.sql =====
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

-- ===== migrations/010_create_payments.sql =====
-- 010: payments
-- Follows the guide: ORDERS 1 -> 1 PAYMENTS. UNIQUE (order_id) lets the database enforce it,
-- so an order can never have two payment rows. A retry after a failed payment updates this
-- same row (new transaction_reference, status back to 'pending').
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
  CONSTRAINT uq_payments_order_id UNIQUE (order_id),
  CONSTRAINT uq_payments_transaction_reference UNIQUE (transaction_reference),
  KEY idx_payments_status (payment_status),
  CONSTRAINT fk_payments_order_id FOREIGN KEY (order_id) REFERENCES orders (order_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_payments_amount CHECK (amount >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ===== migrations/011_create_deliveries.sql =====
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

-- ===== migrations/012_create_reviews.sql =====
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

-- ===== migrations/013_create_password_reset_tokens.sql =====
-- 013: password_reset_tokens  (added: the guide requires password reset but has no table for it)
-- Store only the SHA-256 hash of the token, never the token itself. The raw token goes in the
-- email link; if this table ever leaks, the hashes can't be used to reset anyone's password.
-- Tokens expire (expires_at) and are single-use (used_at is set once consumed).
CREATE TABLE password_reset_tokens (
  token_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED NOT NULL,
  token_hash CHAR(64)     NOT NULL COMMENT 'SHA-256 hex of the emailed token',
  expires_at DATETIME     NOT NULL,
  used_at    DATETIME     NULL DEFAULT NULL,
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (token_id),
  CONSTRAINT uq_password_reset_tokens_hash UNIQUE (token_hash),
  KEY idx_password_reset_tokens_user_id (user_id),
  CONSTRAINT fk_password_reset_tokens_user_id FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ===== seeds/001_seed_roles.sql =====
-- Seed roles. Run once, right after the migrations.
-- IDs are fixed so backend constants can rely on them (1 = admin ... 4 = rider).
INSERT INTO roles (role_id, role_name) VALUES
  (1, 'admin'),
  (2, 'staff'),
  (3, 'customer'),
  (4, 'rider');

-- ===== seeds/002_seed_categories_and_food.sql =====
-- Sample menu for development. Replace with your real menu later.
INSERT INTO categories (category_id, category_name, description) VALUES
  (1, 'Rice Dishes', 'Jollof, fried rice and more'),
  (2, 'Soups & Swallow', 'Traditional soups with your choice of swallow'),
  (3, 'Grills & Protein', 'Suya, grilled fish and chicken'),
  (4, 'Drinks', 'Soft drinks, juices and water');

INSERT INTO food_items (category_id, food_name, description, price) VALUES
  (1, 'Jollof Rice & Chicken', 'Smoky party jollof with grilled chicken', 3500.00),
  (1, 'Fried Rice & Plantain', 'Vegetable fried rice with dodo', 3200.00),
  (2, 'Egusi Soup & Pounded Yam', 'Egusi with assorted meat', 4000.00),
  (2, 'Pepper Soup (Catfish)', 'Hot and spicy catfish pepper soup', 4500.00),
  (3, 'Beef Suya', 'Spicy grilled beef with onions and yaji', 2500.00),
  (3, 'Grilled Tilapia', 'Whole tilapia, pepper sauce', 5500.00),
  (4, 'Chapman', 'Classic Nigerian Chapman', 1500.00),
  (4, 'Bottled Water', '75cl', 300.00);

