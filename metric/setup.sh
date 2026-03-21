#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-Testpass1\$}"
EXPORTER_USER="${EXPORTER_USER:-exporter}"
EXPORTER_PASS="${EXPORTER_PASS:-ExportPass123!}"
LOKI_SERVER="${LOKI_SERVER:-192.168.1.204}"
GRAFANA_ADMIN_PASS="${GRAFANA_ADMIN_PASS:-admin123}"
NODE_EXPORTER_TAG="${NODE_EXPORTER_TAG:-latest}"
PROMETHEUS_TAG="${PROMETHEUS_TAG:-latest}"
GRAFANA_TAG="${GRAFANA_TAG:-latest}"
LOKI_TAG="${LOKI_TAG:-latest}"
PROMTAIL_TAG="${PROMTAIL_TAG:-latest}"

check_deps() {
    command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker not installed"; exit 1; }
    command -v docker compose >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 || \
        { echo "ERROR: Docker Compose not installed"; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not installed"; exit 1; }
}

create_env_file() {
    cat > "$SCRIPT_DIR/.env" << ENVEOF
LOKI_SERVER=${LOKI_SERVER}
GRAFANA_ADMIN_PASS=${GRAFANA_ADMIN_PASS}
NODE_EXPORTER_TAG=${NODE_EXPORTER_TAG}
PROMETHEUS_TAG=${PROMETHEUS_TAG}
GRAFANA_TAG=${GRAFANA_TAG}
LOKI_TAG=${LOKI_TAG}
PROMTAIL_TAG=${PROMTAIL_TAG}
HOSTNAME=$(hostname)
COMPOSE_PROJECT_NAME=monitoring
ENVEOF
    chmod 600 "$SCRIPT_DIR/.env"
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
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: ${HOSTNAME}
          __path__: /var/log/**/*.log
PROMTAILEOF
}

create_prometheus_config() {
    mkdir -p "$SCRIPT_DIR/prometheus"
    cat > "$SCRIPT_DIR/prometheus/prometheus.yml" << 'PROMETHEUSEOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:9090']
  - job_name: 'linux_nodes'
    static_configs:
      - targets:
          - '192.168.1.203:9100'
          - '192.168.1.204:9100'
          - '192.168.1.200:9100'
          - '192.168.1.201:9100'
          - '192.168.1.202:9100'
  - job_name: 'mysql'
    static_configs:
      - targets:
          - '192.168.1.201:9104'
          - '192.168.1.202:9104'
        labels:
          env: 'production'
PROMETHEUSEOF
}

create_loki_config() {
    mkdir -p "$SCRIPT_DIR/loki"
    cat > "$SCRIPT_DIR/loki/local-config.yaml" << 'LOKIEOF'
auth_enabled: false

server:
  http_listen_address: 0.0.0.0
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 336h
  retention_stream:
    - selector: '{job=~".+"}'
      priority: 1
      period: 336h
LOKIEOF
}

create_compose_file() {
    cat > "$SCRIPT_DIR/docker-compose.yml" << COMPOSEEOF
version: '3.8'
services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_TAG}
    container_name: prometheus
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
    ports:
      - "9090:9090"
    restart: unless-stopped
  grafana:
    image: grafana/grafana:${GRAFANA_TAG}
    container_name: grafana
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASS}
    restart: unless-stopped
    depends_on:
      - prometheus
  loki:
    image: grafana/loki:${LOKI_TAG}
    container_name: loki
    ports:
      - "3100:3100"
    command: -config.file=/etc/loki/local-config.yaml
    volumes:
      - ./loki:/etc/loki
      - loki_data:/loki
    restart: unless-stopped
  promtail:
    image: grafana/promtail:${PROMTAIL_TAG}
    container_name: promtail
    volumes:
      - ./promtail-config.yaml:/etc/promtail/config.yml
      - /var/log:/var/log:ro
    command: -config.file=/etc/promtail/config.yml
    restart: unless-stopped
    depends_on:
      - loki
  node-exporter:
    image: quay.io/prometheus/node-exporter:${NODE_EXPORTER_TAG}
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
volumes:
  prometheus_data:
  grafana_data:
  loki_data:
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
    create_positions_dir
    create_promtail_config
    create_prometheus_config
    create_loki_config
    create_compose_file
    start_compose
    echo "http://$(hostname -I | awk '{print $1}'):9090"
    echo "http://$(hostname -I | awk '{print $1}'):3000"
    echo "http://$(hostname -I | awk '{print $1}'):3100"
    echo "http://$(hostname -I | awk '{print $1}'):9100"
}

main "$@"
