-- 000: create the database
-- utf8mb4 stores every character (emoji, accents); the unicode_ci collation
-- gives case-insensitive comparisons, which is what you want for emails/names.
CREATE DATABASE IF NOT EXISTS restaurant_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
