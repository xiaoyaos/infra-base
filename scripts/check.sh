#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib_project_env.sh"
ENV_FILE=""

PROJECT_NAME=""
STRICT="false"
REPORT_PATH=""

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
REPORT_LINES=""

usage() {
  cat <<'USAGE'
用法:
  sh scripts/check.sh --project <name> [--strict] [--report <path>]

说明:
  --project  compose 项目名（必填）
  --strict   严格模式：有失败项即返回非 0
  --report   报告输出路径（默认: ./reports/check_时间戳.md）
USAGE
}

append_line() {
  REPORT_LINES="${REPORT_LINES}$1"$'\n'
}

pass() {
  local msg="$1"
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "[PASS] $msg"
  append_line "- [PASS] $msg"
}

warn() {
  local msg="$1"
  WARN_COUNT=$((WARN_COUNT + 1))
  echo "[WARN] $msg"
  append_line "- [WARN] $msg"
}

fail() {
  local msg="$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "[FAIL] $msg"
  append_line "- [FAIL] $msg"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project|-p)
        PROJECT_NAME="${2:-}"; shift 2 ;;
      --strict)
        STRICT="true"; shift ;;
      --report)
        REPORT_PATH="${2:-}"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "[check] 未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[check] 缺少命令: $1" >&2
    exit 1
  }
}

env_value() {
  local key="$1"
  local default="${2:-}"
  if [ -f "$ENV_FILE" ]; then
    local v
    v="$(awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1); exit}' "$ENV_FILE")"
    if [ -n "$v" ]; then
      echo "$v"
      return 0
    fi
  fi
  echo "$default"
}

is_enabled() {
  local key="$1"
  local v
  v="$(env_value "$key" "true")"
  case "$v" in
    true|TRUE|True|1|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -E "(^|:)$port\$" >/dev/null 2>&1
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1
    return $?
  fi
  return 1
}

container_id() {
  local service="$1"
  docker ps -a \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$service" \
    --format '{{.ID}}' | head -n1
}

container_running() {
  local cid="$1"
  [ -n "$cid" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" = "true" ]
}

check_service_container() {
  local service="$1"
  local cid
  cid="$(container_id "$service")"
  if [ -z "$cid" ]; then
    fail "服务 $service 未找到容器"
    return 1
  fi
  if container_running "$cid"; then
    pass "服务 $service 容器运行中"
    return 0
  fi
  fail "服务 $service 容器存在但未运行"
  return 1
}

check_port_item() {
  local name="$1"
  local port="$2"
  if port_in_use "$port"; then
    pass "$name 端口监听正常: $port"
  else
    fail "$name 端口未监听: $port"
  fi
}

check_pg() {
  local cid
  cid="$(container_id "tsdb")"
  [ -n "$cid" ] || return 0
  local pwd
  pwd="$(env_value "COMMON_PASSWORD" "")"
  if [ -z "$pwd" ]; then
    fail "缺少 COMMON_PASSWORD，无法执行 PostgreSQL 连接检查"
    return 1
  fi
  if docker exec -e PGPASSWORD="$pwd" "$cid" psql -U postgres -d postgres -tAc "select 1" 2>/dev/null | grep -q "^1$"; then
    pass "PostgreSQL 连通性检查通过"
  else
    fail "PostgreSQL 连通性检查失败"
  fi
}

check_mongo() {
  local cid
  cid="$(container_id "mongo")"
  [ -n "$cid" ] || return 0
  local pwd
  pwd="$(env_value "COMMON_PASSWORD" "")"
  if [ -z "$pwd" ]; then
    fail "缺少 COMMON_PASSWORD，无法执行 MongoDB 连接检查"
    return 1
  fi

  local attempt=1
  while [ "$attempt" -le 3 ]; do
    if docker exec "$cid" mongosh --quiet --authenticationDatabase admin -u admin -p "$pwd" --eval 'db.runCommand({ ping: 1 }).ok' 2>/dev/null | grep -q "1"; then
      pass "MongoDB 连通性检查通过"
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      sleep 2
    fi
    attempt=$((attempt + 1))
  done

  fail "MongoDB 连通性检查失败"
}

check_minio() {
  local cid
  cid="$(container_id "minio")"
  [ -n "$cid" ] || return 0
  local pwd
  pwd="$(env_value "COMMON_PASSWORD" "")"
  if [ -z "$pwd" ]; then
    fail "缺少 COMMON_PASSWORD，无法执行 MinIO 连接检查"
    return 1
  fi
  if docker exec "$cid" sh -c "command -v mc >/dev/null 2>&1"; then
    if docker exec "$cid" sh -c "mc alias set local http://127.0.0.1:9000 minio '$pwd' >/dev/null && mc admin info local >/dev/null"; then
      pass "MinIO 连通性检查通过"
    else
      fail "MinIO 连通性检查失败"
    fi
  else
    warn "MinIO 容器缺少 mc，跳过 MinIO 深度检查"
  fi
}

check_static_assets() {
  local f="$BASE_DIR/nginx/www/home_page/services.json"
  if [ -f "$f" ]; then
    pass "静态资源文件存在: nginx/www/home_page/services.json"
  else
    fail "静态资源文件缺失: nginx/www/home_page/services.json"
  fi
}

write_report() {
  local ts
  ts="$(date '+%Y%m%d_%H%M%S')"
  if [ -z "$REPORT_PATH" ]; then
    mkdir -p "$BASE_DIR/reports"
    REPORT_PATH="$BASE_DIR/reports/check_${ts}.md"
  fi
  mkdir -p "$(dirname "$REPORT_PATH")"
  {
    echo "# infra-base 验收报告"
    echo ""
    echo "- 时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- 项目: $PROJECT_NAME"
    echo "- PASS: $PASS_COUNT"
    echo "- WARN: $WARN_COUNT"
    echo "- FAIL: $FAIL_COUNT"
    echo ""
    echo "## 结果明细"
    echo ""
    printf "%s" "$REPORT_LINES"
  } > "$REPORT_PATH"
  echo "[check] 报告已生成: $REPORT_PATH"
}

main() {
  parse_args "$@"

  [ -n "$PROJECT_NAME" ] || {
    echo "[check] --project 必填" >&2
    usage
    exit 1
  }
  if ! project_name_is_valid "$PROJECT_NAME"; then
    echo "[check] 非法项目名称: $PROJECT_NAME" >&2
    exit 1
  fi

  ENV_FILE="$(resolve_project_env_file "$PROJECT_NAME")"

  require_cmd docker
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    echo "[check] 未检测到 docker compose" >&2
    exit 1
  fi

  echo "[check] 开始检查 project: $PROJECT_NAME"

  # 1) 容器状态
  is_enabled "ENABLE_TSDB" && check_service_container "tsdb"
  is_enabled "ENABLE_REDIS" && check_service_container "redis"
  is_enabled "ENABLE_NGINX" && check_service_container "nginx"
  is_enabled "ENABLE_MINIO" && check_service_container "minio"
  is_enabled "ENABLE_EMQX" && check_service_container "emqx"
  is_enabled "ENABLE_MONGO" && check_service_container "mongo"
  is_enabled "ENABLE_ETCD" && check_service_container "etcd"
  is_enabled "ENABLE_APISIX" && check_service_container "apisix"
  is_enabled "ENABLE_APISIX_DASHBOARD" && check_service_container "apisix-dashboard"

  # 2) 端口监听
  is_enabled "ENABLE_TSDB" && check_port_item "TSDB_PORT" "$(env_value TSDB_PORT 5432)"
  is_enabled "ENABLE_REDIS" && check_port_item "REDIS_PORT" "$(env_value REDIS_PORT 6379)"
  if is_enabled "ENABLE_NGINX"; then
    check_port_item "NGINX_HTTPS_PORT" "$(env_value NGINX_HTTPS_PORT 443)"
    check_port_item "NGINX_HTTP_PORT" "$(env_value NGINX_HTTP_PORT 80)"
    check_port_item "NGINX_HTTP_ALT_PORT" "$(env_value NGINX_HTTP_ALT_PORT 80)"
  fi
  if is_enabled "ENABLE_MINIO"; then
    check_port_item "MINIO_API_PORT" "$(env_value MINIO_API_PORT 9000)"
    check_port_item "MINIO_CONSOLE_PORT" "$(env_value MINIO_CONSOLE_PORT 9001)"
  fi
  if is_enabled "ENABLE_EMQX"; then
    check_port_item "EMQX_MQTT_PORT" "$(env_value EMQX_MQTT_PORT 1883)"
    check_port_item "EMQX_HTTP_API_PORT" "$(env_value EMQX_HTTP_API_PORT 8081)"
    check_port_item "EMQX_WS_PORT" "$(env_value EMQX_WS_PORT 8083)"
    check_port_item "EMQX_SSL_MQTT_PORT" "$(env_value EMQX_SSL_MQTT_PORT 8883)"
    check_port_item "EMQX_WSS_PORT" "$(env_value EMQX_WSS_PORT 8084)"
    check_port_item "EMQX_DASHBOARD_PORT" "$(env_value EMQX_DASHBOARD_PORT 18083)"
  fi
  is_enabled "ENABLE_MONGO" && check_port_item "MONGO_PORT" "$(env_value MONGO_PORT 27017)"
  is_enabled "ENABLE_APISIX_DASHBOARD" && check_port_item "APISIX_DASHBOARD_PORT" "$(env_value APISIX_DASHBOARD_PORT 9000)"

  # 3) 中间件连通性
  is_enabled "ENABLE_TSDB" && check_pg
  is_enabled "ENABLE_MONGO" && check_mongo
  is_enabled "ENABLE_MINIO" && check_minio

  # 4) 静态资源
  check_static_assets

  write_report

  echo "[check] 汇总: PASS=$PASS_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"
  if [ "$STRICT" = "true" ] && [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
