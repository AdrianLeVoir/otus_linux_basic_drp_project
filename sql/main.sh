#!/usr/bin/env bash
set -euo pipefail

#КОНФИГУРАЦИЯ
MYSQL_PASS='Testpass1$'
MASTER="minerva"
REPLICA="pomona"
MASTER_IP="192.168.1.201"
SSH_USER="adrianl"
BACKUP_DIR="/backups"
BACKUP_SCRIPT="/usr/local/bin/mariadb-backup.sh"
RESTORE_SCRIPT="/usr/local/bin/mariadb-restore.sh"

#ХЕЛПЕРЫ
run_sudo() {
    local host="$1"
    local cmd="$2"
    ssh "$host" "sudo bash -c \"$cmd\"" 2>&1
}

run_mysql() {
    local host="$1"
    local query="$2"
    ssh "$host" "sudo mysql -u root -p'Testpass1\$' -e \"$query\"" 2>&1
}

check_mariadb() {
    local host="$1"
    sleep 2
    if ! ssh "$host" "sudo systemctl is-active --quiet mariadb"; then
        echo " MariaDB не запущен на $host"
        ssh "$host" "sudo journalctl -u mariadb --no-pager -n 15" || true
        return 1
    fi
    echo "MariaDB активен на $host"
    return 0
}

check_replication() {
    local status
    status=$(run_mysql "$REPLICA" "SHOW SLAVE STATUS\G" | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_SQL_Error')
    echo "$status"
    if echo "$status" | grep -q "Slave_IO_Running: Yes" && echo "$status" | grep -q "Slave_SQL_Running: Yes"; then
        return 0
    fi
    return 1
}

simulate_breakage() {
    echo ""
    echo "Выберите тип поломки для теста:"
    echo " 1) Репликация остановлена (STOP SLAVE)"
    echo " 2) Полный сброс позиции репликации (RESET SLAVE ALL)"
    echo " 3) MariaDB на реплике остановлен"
    echo " 4) Пользователь repl удалён с мастера"
    echo " 5) Пароль repl изменён на неверный"
    echo " 0) ← назад"
    echo "────────────────────────────────────────"
    read -p "Выбор: " break_choice
    echo ""

    case $break_choice in
        1)
            echo "репликация остановлена"
            run_mysql "$REPLICA" "STOP SLAVE;"
            ;;
        2)
            echo "сброшена позиция репликации"
            run_mysql "$REPLICA" "STOP SLAVE;"
            run_mysql "$REPLICA" "RESET SLAVE ALL;"
            ;;
        3)
            echo "MariaDB на реплике остановлен"
            run_sudo "$REPLICA" "systemctl stop mariadb"
            ;;
        4)
            echo "пользователь repl удалён"
            run_mysql "$MASTER" "DROP USER IF EXISTS 'repl'@'%'; FLUSH PRIVILEGES;"
            ;;
        5)
            echo "пароль repl изменён на неверный"
            run_mysql "$MASTER" "ALTER USER 'repl'@'%' IDENTIFIED BY 'WrongPass!!!'; FLUSH PRIVILEGES;"
            ;;
        0) return ;;
        *) echo "Неверный выбор" ; return ;;
    esac

    echo ""
    echo "Поломка выполнена."
    echo "Текущее состояние репликации:"
    echo "────────────────────────────────────────"
    run_mysql "$REPLICA" "SHOW SLAVE STATUS\G" | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_.*Error|Error' || echo "(нет вывода или ошибка подключения)"

    echo ""
    echo "Перезапустите скрипт и выберите режим"
    echo "Автофикс"
    echo "Скрипт в режиме 2 должен самостоятельно починить эту поломку."
    echo ""
}

#МЕНЮ КОМАНД
show_commands_menu() {
    while true; do
        echo ""
        echo "ВЫБЕРИТЕ ДЕЙСТВИЕ:"
        echo " 1) Создать бэкап"
        echo " 2) Восстановить из последнего бэкапа"
        echo " 3) Показать cron"
        echo " 4) Список всех бэкапов"
        echo " 5) Список баз данных"
        echo " 6) Таблицы sakila"
        echo " 7) Таблицы sakila + кол-во строк"
        echo " 8) Статус реплики"
        echo " 9) Активные процессы MySQL"
        echo " 10) Тестовая поломка"
        echo ""
        echo " 0) Выход"
        echo "────────────────────────────────────────"
        read -p "Выбор: " choice
        echo ""

        case $choice in
            1) run_sudo "$MASTER" "$BACKUP_SCRIPT" && ssh "$MASTER" "sudo ls -lth $BACKUP_DIR | head -6" ;;
            2) run_sudo "$MASTER" "$RESTORE_SCRIPT" ;;
            3) run_sudo "$MASTER" "crontab -l || echo 'Нет cron задач'" ;;
            4) ssh "$MASTER" "sudo ls -lth $BACKUP_DIR 2>/dev/null || echo 'Директория пуста'" ;;
            5) run_mysql "$MASTER" "SHOW DATABASES;" ;;
            6) run_mysql "$MASTER" "USE sakila; SHOW TABLES;" ;;
            7) run_mysql "$MASTER" "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='sakila' AND table_type='BASE TABLE';" ;;
            8) run_mysql "$REPLICA" "SHOW SLAVE STATUS\G" | grep -E 'Slave_IO|Slave_SQL|Seconds_Behind|Master_Host|Last_SQL_Error' || echo "Репликация не настроена" ;;
            9) run_mysql "$REPLICA" "SHOW PROCESSLIST;" ;;
            10) simulate_breakage ;;
            0) echo "Выход."; break ;;
            *) echo "Неверный выбор" ;;
        esac

        [[ $choice != 0 ]] && read -p "Продолжить? (y/n) " cont && [[ $cont =~ ^[nN] ]] && break
    done
}

#ГЛАВНОЕ МЕНЮ
echo "Режим:"
echo "1) Полная переустановка (все данные будут удалены!)"
echo "2) Автофикс"
echo "3) Управление системой (меню команд)"
read -p "Выбор (1-3): " mode

if [[ $mode == 3 ]]; then
    show_commands_menu
    exit 0
fi

if [[ $mode != 1 && $mode != 2 ]]; then
    echo "Неверный режим. Выход."
    exit 1
fi

if [[ $mode == 1 ]]; then
    echo -e "\n⚠ПОЛНОЕ УДАЛЕНИЕ ДАННЫХ"
    read -p "Подтвердите удаление (yes): " confirm
    [[ $confirm != "yes" ]] && echo "Отменено." && exit 0
fi

#ОСНОВНАЯ ЛОГИКА
echo -e "\nНачинаем настройку ($mode)"

for h in "$MASTER" "$REPLICA"; do
    if ! ssh "$h" "sudo systemctl is-active --quiet mariadb"; then
        echo "[$h] MariaDB не запущен, запускаем..."
        run_sudo "$h" "systemctl start mariadb"
        sleep 5
        if ! ssh "$h" "sudo systemctl is-active --quiet mariadb"; then
            echo "[$h] Не удалось запустить MariaDB! Смотрите логи:"
            ssh "$h" "sudo journalctl -u mariadb -n 30"
            exit 1
        fi
    fi
done

if [[ $mode == 1 ]]; then
    for h in "$MASTER" "$REPLICA"; do
        echo "[$h] Переустановка MariaDB..."
        run_sudo "$h" "
            systemctl stop mariadb || true
            apt remove --purge -y mariadb-server mariadb-client 2>/dev/null || true
            apt autoremove -y
            rm -rf /var/lib/mysql /var/log/mysql
            apt update -qq
            apt install -y mariadb-server mariadb-client prometheus-node-exporter cron
        "
    done
else
    run_sudo "$MASTER" "apt update -qq && apt install -y cron || true"
fi

# Мастер конфиг
run_sudo "$MASTER" "
    mkdir -p /var/log/mysql
    chown mysql:mysql /var/log/mysql
    cat > /etc/mysql/mariadb.conf.d/50-server.cnf <<'EOF'
[mysqld]
bind-address     = 0.0.0.0
server-id        = 1
log_bin          = /var/log/mysql/mariadb-bin
binlog_format    = ROW
gtid_domain_id   = 0
gtid_strict_mode = OFF
log_slave_updates= ON
max_binlog_size  = 100M
character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
skip-name-resolve
EOF
    chown root:root /etc/mysql/mariadb.conf.d/50-server.cnf
    chmod 644 /etc/mysql/mariadb.conf.d/50-server.cnf
"

# Реплика конфиг
run_sudo "$REPLICA" "
    mkdir -p /var/log/mysql
    chown mysql:mysql /var/log/mysql
    cat > /etc/mysql/mariadb.conf.d/50-server.cnf <<'EOF'
[mysqld]
bind-address     = 127.0.0.1
server-id        = 2
log_bin          = /var/log/mysql/mariadb-bin
binlog_format    = ROW
relay_log        = /var/log/mysql/relay-log
read_only        = ON
gtid_domain_id   = 0
gtid_strict_mode = OFF
log_slave_updates= ON
character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
skip-name-resolve
EOF
    chown root:root /etc/mysql/mariadb.conf.d/50-server.cnf
    chmod 644 /etc/mysql/mariadb.conf.d/50-server.cnf
"

# Установка пароля root
for h in "$MASTER" "$REPLICA"; do
    echo "[$h] Проверка root-доступа..."
    if ssh "$h" "sudo mysql -u root -e 'SELECT 1' >/dev/null 2>&1"; then
        echo "[$h] Доступ через unix_socket, задаём пароль"
        ssh "$h" "sudo mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('Testpass1\\\$'); FLUSH PRIVILEGES;\""
    else
        if ssh "$h" "sudo mysql -u root -p'Testpass1\$' -e 'SELECT 1' >/dev/null 2>&1"; then
            echo "[$h] Пароль уже установлен и работает"
        else
            echo "[$h] Пароль не подходит, принудительно переустанавливаем"
            ssh "$h" "sudo mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('Testpass1\\\$'); FLUSH PRIVILEGES;\""
        fi
    fi
done

# Перезапуск
for h in "$MASTER" "$REPLICA"; do
    run_sudo "$h" "systemctl restart mariadb"
    sleep 3
    check_mariadb "$h" || exit 1
done

# Настройка репликации
echo "[$MASTER] Создание/обновление пользователя repl..."
ssh "$MASTER" "sudo mysql -u root -p'Testpass1\$' -e \"
    DROP USER IF EXISTS 'repl'@'%';
    CREATE USER 'repl'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$MYSQL_PASS');
    GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
    FLUSH PRIVILEGES;
\""

# Сброс мастера ПЕРЕД импортом
echo "[$MASTER] Сброс бинарных логов..."
ssh "$MASTER" "sudo mysql -u root -p'Testpass1\$' -e 'RESET MASTER;'"

# Функция импорта
import_sakila() {
    local host="$1"
    echo "[$host] Импорт sak.sql..."

    # 1. Создаём базу
    ssh "$host" "sudo mysql -u root -p'Testpass1\$' -e 'CREATE DATABASE IF NOT EXISTS sakila CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"

    if ssh "$host" "test -f /home/$SSH_USER/sak.sql"; then
        echo "  Найден /home/$SSH_USER/sak.sql"
        echo "  Конвертация коллаций MySQL 8, MariaDB 10..."
        # 2. Импортируем с указанием базы sakila в конце команды
        ssh "$host" "cat /home/$SSH_USER/sak.sql | \
            sed 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' | \
            sed 's/utf8mb4_general_ci/utf8mb4_unicode_ci/g' | \
            sudo mysql -u root -p'Testpass1\$' sakila"
    elif ssh "$host" "test -f /tmp/sak.sql"; then
        echo "  Найден /tmp/sak.sql"
        ssh "$host" "cat /tmp/sak.sql | \
            sed 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' | \
            sed 's/utf8mb4_general_ci/utf8mb4_unicode_ci/g' | \
            sudo mysql -u root -p'Testpass1\$' sakila"
    else
        echo "sak.sql не найден, создаём тестовые данные"
        ssh "$host" "sudo mysql -u root -p'Testpass1\$' -e \"
            USE sakila;
            CREATE TABLE IF NOT EXISTS test_replication (
                id INT AUTO_INCREMENT PRIMARY KEY,
                msg VARCHAR(200),
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            INSERT INTO test_replication (msg) VALUES ('Initial data');
        \""
        return
    fi

    echo "  Создание тестовой таблицы..."
    ssh "$host" "sudo mysql -u root -p'Testpass1\$' -e \"
        USE sakila;
        CREATE TABLE IF NOT EXISTS test_replication (
            id INT AUTO_INCREMENT PRIMARY KEY,
            msg VARCHAR(200),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        INSERT IGNORE INTO test_replication (msg) VALUES ('Initial data after import');
    \""
}

# ИМПОРТ НА ОБА СЕРВЕРА
import_sakila "$MASTER"
import_sakila "$REPLICA"

# Получаем позицию НА МАСТЕРЕ после импорта
read -r binlog_file binlog_pos < <(ssh "$MASTER" "sudo mysql -u root -p'Testpass1\$' -e 'SHOW MASTER STATUS' | tail -1 | awk '{print \$1, \$2}'")

echo "[$REPLICA] Настройка репликации (позиция: $binlog_file:$binlog_pos)..."
ssh "$REPLICA" "sudo mysql -u root -p'Testpass1\$' -e \"
    STOP SLAVE;
    RESET SLAVE ALL;
    CHANGE MASTER TO
        MASTER_HOST='$MASTER_IP',
        MASTER_USER='repl',
        MASTER_PASSWORD='$MYSQL_PASS',
        MASTER_LOG_FILE='$binlog_file',
        MASTER_LOG_POS=$binlog_pos;
    START SLAVE;
\""
sleep 5

# Бэкапы
run_sudo "$MASTER" "
    mkdir -p $BACKUP_DIR
    chown mysql:mysql $BACKUP_DIR
    chmod 770 $BACKUP_DIR
"

#Создание скрипта бэкапа
ssh "$MASTER" "sudo tee $BACKUP_SCRIPT > /dev/null" << 'BACKUPEOF'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/backups"
DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FOLDER="$BACKUP_DIR/backup_$DATE"
mkdir -p "$BACKUP_FOLDER"
PASS='Testpass1$'
DATABASES=$(mysql -u root -p"$PASS" -N -e "SHOW DATABASES" | grep -vE '^(information_schema|performance_schema|sys|mysql)$')
for db in $DATABASES; do
    mkdir -p "$BACKUP_FOLDER/$db"
    mysqldump -u root -p"$PASS" \
        --single-transaction --routines --triggers \
        "$db" > "$BACKUP_FOLDER/$db/full.sql"
done
find "$BACKUP_DIR" -type d -name "backup_*" -mtime +7 -exec rm -rf {} +
echo "Бэкап: $BACKUP_FOLDER"
ls -lh "$BACKUP_FOLDER"
BACKUPEOF

run_sudo "$MASTER" "chmod 755 $BACKUP_SCRIPT"

#Скрипт восстановления
ssh "$MASTER" "sudo tee $RESTORE_SCRIPT > /dev/null" << 'RESTOREEOF'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/backups"
PASS='Testpass1$'
LATEST=$(ls -td "$BACKUP_DIR"/backup_* 2>/dev/null | head -1)
[ -z "$LATEST" ] && echo "Нет бэкапов" && exit 1
for db_dir in "$LATEST"/*/; do
    db=$(basename "$db_dir")
    mysql -u root -p"$PASS" -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db;"
    mysql -u root -p"$PASS" "$db" < "$db_dir/full.sql"
done
echo "Восстановление завершено"
RESTOREEOF

run_sudo "$MASTER" "chmod 755 $RESTORE_SCRIPT"

# Cron
run_sudo "$MASTER" "
    (crontab -l 2>/dev/null | grep -v mariadb-backup.sh;
     echo '0 2 * * * $BACKUP_SCRIPT') | crontab -
"

# Тестовый бэкап
echo "Тестовый бэкап..."
run_sudo "$MASTER" "$BACKUP_SCRIPT"

#Проверка репликации
echo -e "\nПроверка репликации:"
if check_replication; then
    echo "Репликация работает (IO и SQL трейды Yes, отставание 0 сек)"
    echo "Проверка данных на MASTER:"
    ssh "$MASTER"  "sudo mysql -u root -p'Testpass1\$' -e 'USE sakila; SELECT film_id, title, last_update FROM film ORDER BY last_update DESC LIMIT 3;'"
    echo "Проверка данных на REPLICA:"
    ssh "$REPLICA" "sudo mysql -u root -p'Testpass1\$' -e 'USE sakila; SELECT film_id, title, last_update FROM film ORDER BY last_update DESC LIMIT 3;'"
else
    echo "Проблема с репликацией"
    ssh "$REPLICA" "sudo mysql -u root -p'Testpass1\$' -e 'SHOW SLAVE STATUS\G'" | grep -E 'Last_SQL_Error|Last_IO_Error|Error'
fi

echo -e "\nДЕПЛОЙ ЗАВЕРШЁН"
echo "---------------------"
echo "Бэкапы:     $BACKUP_DIR"
echo "Cron:       02:00 ежедневно"
echo ""

show_commands_menu
