-- 001: roles
-- A lookup table instead of an ENUM: adding a role later is an INSERT,
-- not an ALTER TABLE on a big users table.
CREATE TABLE roles (
  role_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  role_name VARCHAR(30)  NOT NULL,
  PRIMARY KEY (role_id),
  CONSTRAINT uq_roles_role_name UNIQUE (role_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
