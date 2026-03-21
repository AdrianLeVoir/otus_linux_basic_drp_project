#!/usr/bin/env bash
set -euo pipefail

MASTER="minerva"
REPLICA="pomona"

BACKUP_DIR="/backups"
BACKUP_SCRIPT="/usr/local/bin/mariadb-backup.sh"
RESTORE_SCRIPT="/usr/local/bin/mariadb-restore.sh"

run_sudo() {
    local host="$1"
    local cmd="$2"
    ssh "$host" "sudo bash -c \"$cmd\"" 2>&1
}

read -p "Confirm (yes): " confirm
[[ "$confirm" != "yes" ]] && exit 0

for h in "$MASTER" "$REPLICA"; do
    run_sudo "$h" "
        systemctl stop mariadb 2>/dev/null || true

        rm -rf /var/lib/mysql/*
        rm -rf /var/log/mysql/*

        rm -f /etc/mysql/mariadb.conf.d/50-server.cnf

        mkdir -p /var/lib/mysql /var/log/mysql
        chown -R mysql:mysql /var/lib/mysql /var/log/mysql

        (systemctl start mariadb 2>/dev/null) || (
            mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1 && \
            systemctl start mariadb
        )

        rm -rf $BACKUP_DIR
        rm -f $BACKUP_SCRIPT
        rm -f $RESTORE_SCRIPT

        crontab -l 2>/dev/null | grep -v 'mariadb-backup.sh' | crontab - || true
    "
done

echo "DONE"
