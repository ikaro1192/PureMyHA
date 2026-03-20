-- Monitoring user for puremyhad
CREATE USER IF NOT EXISTS 'puremyha'@'%' IDENTIFIED BY 'puremyha_pass';
GRANT SELECT, RELOAD, PROCESS, SUPER, REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'puremyha'@'%';

-- Replication user
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY 'repl_pass';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

-- Test database for write verification
CREATE DATABASE IF NOT EXISTS e2e_test;
USE e2e_test;
CREATE TABLE IF NOT EXISTS heartbeat (
  id INT PRIMARY KEY,
  ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
INSERT INTO heartbeat VALUES (1, NOW());
