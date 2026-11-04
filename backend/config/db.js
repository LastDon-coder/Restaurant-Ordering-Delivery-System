// One shared connection pool for the whole app.
// A pool keeps up to 10 connections open and hands them out per query, so requests don't
// each pay the cost of opening a new connection.
// Always query with pool.execute(sql, [values]): the ? placeholders are sent to MySQL
// separately from the values, which is what prevents SQL injection.
const mysql = require('mysql2/promise');
const { db } = require('./env');

const pool = mysql.createPool({
  host: db.host,
  port: db.port,
  user: db.user,
  password: db.password,
  database: db.database,
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0,
});

module.exports = pool;
