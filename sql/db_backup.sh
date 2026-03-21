#!/bin/bash

BACKUP_DIR="/backups"
mkdir -p $BACKUP_DIR

DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_DIR1="$BACKUP_DIR/backup_$DATE"
mkdir -p "$BACKUP_FOLDER"

USER="root"
PASSWORD="Testpass1$"

DATABASES=$(mysql -u$USER -p$PASSWORD -e "SHOW DATABASES;" | grep -v Database | grep -v information_schema | grep -v performance_schema | grep -v sys | grep -v mysql)

for DB in $DATABASES; do
    echo "Бэкап базы: $DB"

    mkdir -p "$BACKUP_DIR1/$DB"

    TABLES=$(mysql -u$USER -p$PASSWORD -e "USE $DB; SHOW TABLES;" | grep -v Tables_in)

    for TABLE in $TABLES; do
        echo "  Сохраняется таблица: $TABLE"

        mysqldump -u$USER -p$PASSWORD \
            --set-gtid-purged=OFF \
	    "$DB" "$TABLE" \
            > "$BACKUP_DIR1/$DB/$TABLE.sql" 2>/dev/null
	echo "  Таблица $TABLE сохранена"
    done
done

mysql -u"$USER" -p"$PASSWORD" -e "SHOW SLAVE STATUS\G" > "$BACKUP_DIR1/slave-status_$DATE.txt" 2>/dev/null
mysql -u"$USER" -p"$PASSWORD" -e "SHOW MASTER STATUS\G" > "$BACKUP_DIR1/master-status_$DATE.txt" 2>/dev/null

if [ $? -eq 0 ]; then
    echo ""
    echo "Бэкап успешно создан: $BACKUP_DIR1"
    tree "$BACKUP_DIR1"
else
    echo "Ошибка при создании бэкапа"
fi
