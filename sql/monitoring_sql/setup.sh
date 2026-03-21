#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-Testpass1\$}"
EXPORTER_USER="${EXPORTER_USER:-exporter}"
EXPORTER_PASS="${EXPORTER_PASS:-ExportPass123!}"
LOKI_SERVER="${LOKI_SERVER:-192.168.1.204}"

check_deps() {
    command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker not installed"; exit 1; }
    command -v docker compose >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 || \
        { echo "ERROR: Docker Compose not installed"; exit 1; }
    command -v mysql >/dev/null 2>&1 || { echo "ERROR: MySQL client not installed"; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not installed"; exit 1; }
}

create_env_file() {
    cat > "$SCRIPT_DIR/.env" << ENVEOF
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS}
EXPORTER_USER=${EXPORTER_USER}
EXPORTER_PASS=${EXPORTER_PASS}
NODE_EXPORTER_TAG=latest
MYSQL_EXPORTER_TAG=latest
PROMTAIL_TAG=latest
LOKI_SERVER=${LOKI_SERVER}
HOSTNAME=$(hostname)
COMPOSE_PROJECT_NAME=monitoring
ENVEOF
    chmod 600 "$SCRIPT_DIR/.env"
}

create_exporter_config() {
    cat > "$SCRIPT_DIR/mysqld_exporter.cnf" << CNFEOF
[client]
user=${EXPORTER_USER}
password=${EXPORTER_PASS}
CNFEOF
    chmod 644 "$SCRIPT_DIR/mysqld_exporter.cnf"
}

create_positions_dir() {
    mkdir -p "$SCRIPT_DIR/positions"
}

create_promtail_config() {
    cat > "$SCRIPT_DIR/promtail-config.yaml" << PROMTAILEOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://${LOKI_SERVER}:3100/loki/api/v1/push

scrape_configs:
  - job_name: varlogs
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: ${HOSTNAME}
          __path__: /var/log/**/*.log
PROMTAILEOF

    chmod 644 "$SCRIPT_DIR/promtail-config.yaml"
}

setup_mysql_user() {
    local escaped_pass="${EXPORTER_PASS//\'/\'\'}"
    sudo mysql -u root -p"${MYSQL_ROOT_PASS}" -e "
        CREATE USER IF NOT EXISTS '${EXPORTER_USER}'@'127.0.0.1'
        IDENTIFIED VIA mysql_native_password USING PASSWORD('${escaped_pass}');
        CREATE USER IF NOT EXISTS '${EXPORTER_USER}'@'localhost'
        IDENTIFIED VIA mysql_native_password USING PASSWORD('${escaped_pass}');
        GRANT SUPER, REPLICATION CLIENT, PROCESS, SELECT ON *.* TO '${EXPORTER_USER}'@'127.0.0.1';
        GRANT SUPER, REPLICATION CLIENT, PROCESS, SELECT ON *.* TO '${EXPORTER_USER}'@'localhost';
        FLUSH PRIVILEGES;
    "
}

create_compose_file() {
    local abs_path="$(realpath "$SCRIPT_DIR/mysqld_exporter.cnf")"

    cat > "$SCRIPT_DIR/docker-compose.yml" << COMPOSEEOF
version: '3.9'

services:
  node-exporter:
    image: quay.io/prometheus/node-exporter:\${NODE_EXPORTER_TAG}
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
    networks:
      - monitoring

  mysqld-exporter:
    image: prom/mysqld-exporter:\${MYSQL_EXPORTER_TAG}
    container_name: mysqld-exporter
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${abs_path}:/etc/mysqld_exporter.cnf:ro
    command:
      - '--config.my-cnf=/etc/mysqld_exporter.cnf'

  promtail:
    image: grafana/promtail:\${PROMTAIL_TAG}
    container_name: promtail
    restart: unless-stopped
    ports:
      - "9080:9080"
    volumes:
      - /var/log:/var/log:ro
      - ./promtail-config.yaml:/etc/promtail/promtail-config.yaml:ro
      - ./positions:/tmp
    command:
      - -config.file=/etc/promtail/promtail-config.yaml
      - -config.expand-env=true
    environment:
      - HOSTNAME=\${HOSTNAME}
      - LOKI_SERVER=\${LOKI_SERVER}
    networks:
      - monitoring

networks:
  monitoring:
    driver: bridge
COMPOSEEOF
}

start_compose() {
    cd "$SCRIPT_DIR"
    docker compose down 2>/dev/null || true
    docker compose up -d
}

main() {
    check_deps
    create_env_file
    create_exporter_config
    create_positions_dir
    create_promtail_config
    setup_mysql_user
    create_compose_file
    start_compose
    echo "Node-exporter: http://$(hostname -I | awk '{print $1}'):9100/metrics"
    echo "MySQL-exporter: http://$(hostname -I | awk '{print $1}'):9104/metrics"
    echo "Promtail: http://$(hostname -I | awk '{print $1}'):9080/metrics"
}

main "$@"
