-- Monitoring user for puremyhad
CREATE USER IF NOT EXISTS 'puremyha'@'%' IDENTIFIED BY 'puremyha_pass';
GRANT SELECT, RELOAD, PROCESS, SUPER, REPLICATION CLIENT, REPLICATION SLAVE, BACKUP_ADMIN, CLONE_ADMIN ON *.* TO 'puremyha'@'%';

-- Replication user
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY 'repl_pass';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

