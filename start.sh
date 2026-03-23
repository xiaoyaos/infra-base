#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
INFRA_SELECTED=""
APISIX_SELECTED=""

PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
  read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
fi
if [ -z "$PROJECT_NAME" ]; then
  echo "[start] 项目名称不能为空" >&2
  exit 1
fi

export COMPOSE_PROJECT_NAME="$PROJECT_NAME"
export NETWORK_NAME="${NETWORK_NAME:-infra-base-${COMPOSE_PROJECT_NAME}}"

echo "[start] 生成服务端口清单..."
"$SCRIPT_DIR/scripts/generate_services.sh"

SUDO=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[start] 未找到 docker，请先运行 install.sh" >&2
  exit 1
fi

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    return 1
  fi
}

COMPOSE_BIN="$(compose_cmd)" || {
  echo "[start] 未检测到 docker compose" >&2
  exit 1
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

collect_host_ports() {
  local file="$1"
  local targets_csv="${2:-}"
  awk -v targets="$targets_csv" '
  BEGIN {
    in_ports=0;
    svc="";
    active=0;
    n=split(targets, arr, ",");
    for (i=1;i<=n;i++) if (arr[i]!="") t[arr[i]]=1;
  }
  function is_target(s) {
    if (targets=="") return 1;
    return (s in t);
  }
  {
    if ($0 ~ /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*$/) {
      line=$0;
      sub(/^[[:space:]]{2}/, "", line);
      sub(/:[[:space:]]*$/, "", line);
      svc=line;
      active=is_target(svc);
      in_ports=0;
      next;
    }
    if ($0 ~ /^[[:space:]]{4}ports:[[:space:]]*$/) {
      in_ports=active ? 1 : 0;
      next;
    }
    if (in_ports) {
      if ($0 !~ /^[[:space:]]{6}-/) { in_ports=0; next; }
      line=$0;
      sub(/^[[:space:]]{6}-[[:space:]]*/, "", line);
      gsub(/"/, "", line);
      gsub(/[[:space:]]+/, "", line);
      n=split(line, parts, ":");
      if (n==2) { host=parts[1]; }
      else if (n>=3) { host=parts[2]; }
      else { host=""; }
      sub(/\/.*/, "", host);
      if (host ~ /^[0-9]+$/) print host;
    }
  }' "$file"
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

build_selected_services() {
  INFRA_SELECTED=""
  APISIX_SELECTED=""

  is_enabled "ENABLE_TSDB" && INFRA_SELECTED="$INFRA_SELECTED tsdb"
  is_enabled "ENABLE_REDIS" && INFRA_SELECTED="$INFRA_SELECTED redis"
  is_enabled "ENABLE_NGINX" && INFRA_SELECTED="$INFRA_SELECTED nginx"
  is_enabled "ENABLE_MINIO" && INFRA_SELECTED="$INFRA_SELECTED minio"
  is_enabled "ENABLE_EMQX" && INFRA_SELECTED="$INFRA_SELECTED emqx"
  is_enabled "ENABLE_MONGO" && INFRA_SELECTED="$INFRA_SELECTED mongo"

  if is_enabled "ENABLE_ETCD"; then
    APISIX_SELECTED="$APISIX_SELECTED etcd"
  fi
  if is_enabled "ENABLE_APISIX"; then
    APISIX_SELECTED="$APISIX_SELECTED apisix"
    if ! is_enabled "ENABLE_ETCD"; then
      echo "[start] 检测到 ENABLE_APISIX=true 且 ENABLE_ETCD!=true，自动补启 etcd"
      APISIX_SELECTED="$APISIX_SELECTED etcd"
    fi
  fi
  if is_enabled "ENABLE_APISIX_DASHBOARD"; then
    APISIX_SELECTED="$APISIX_SELECTED apisix-dashboard"
  fi
}

changed_services_for_compose() {
  local file="$1"
  local services hashes
  if [ -f "$ENV_FILE" ]; then
    services="$($COMPOSE_BIN --env-file "$ENV_FILE" -f "$file" config --services 2>/dev/null || true)"
  else
    services="$($COMPOSE_BIN -f "$file" config --services 2>/dev/null || true)"
  fi
  if [ -z "$services" ]; then
    echo "__ALL__"
    return 0
  fi
  if [ -f "$ENV_FILE" ]; then
    hashes="$(echo "$services" | while read -r s; do
      [ -z "$s" ] && continue
      $COMPOSE_BIN --env-file "$ENV_FILE" -f "$file" config --hash "$s" 2>/dev/null
    done)"
  else
    hashes="$(echo "$services" | while read -r s; do
      [ -z "$s" ] && continue
      $COMPOSE_BIN -f "$file" config --hash "$s" 2>/dev/null
    done)"
  fi
  if [ -z "$hashes" ]; then
    echo "__ALL__"
    return 0
  fi
  local changed=()
  while read -r svc hash; do
    [ -z "$svc" ] && continue
    local labels
    labels="$(docker ps -a \
      --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
      --filter "label=com.docker.compose.service=$svc" \
      --format '{{.Labels}}')"
    if [ -z "$labels" ]; then
      changed+=("$svc")
      continue
    fi
    local same=1
    while read -r line; do
      [ -z "$line" ] && continue
      local cur
      cur="$(echo "$line" | tr ',' '\n' | awk -F= '$1=="com.docker.compose.config-hash"{print $2; exit}')"
      if [ -z "$cur" ] || [ "$cur" != "$hash" ]; then
        same=0
        break
      fi
    done <<< "$labels"
    if [ "$same" -eq 0 ]; then
      changed+=("$svc")
    fi
  done <<< "$hashes"
  if [ ${#changed[@]} -eq 0 ]; then
    echo ""
  else
    printf '%s\n' "${changed[@]}"
  fi
}

check_ports_in_compose() {
  local file="$1"
  local forced_services="${2:-}"
  local services
  if [ -n "$forced_services" ]; then
    services="$(echo "$forced_services" | xargs -n1)"
  else
    services="$(changed_services_for_compose "$file")"
    if [ "$services" = "__ALL__" ]; then
      if [ -f "$ENV_FILE" ]; then
        services="$($COMPOSE_BIN --env-file "$ENV_FILE" -f "$file" config --services 2>/dev/null || true)"
      else
        services="$($COMPOSE_BIN -f "$file" config --services 2>/dev/null || true)"
      fi
    fi
  fi
  if [ -z "$services" ]; then
    echo "[start] 未检测到需要变更的服务，跳过端口检查: $file"
    return 0
  fi
  local resolved_file
  resolved_file="$(mktemp)"
  if [ -f "$ENV_FILE" ]; then
    $COMPOSE_BIN --env-file "$ENV_FILE" -f "$file" config > "$resolved_file"
  else
    $COMPOSE_BIN -f "$file" config > "$resolved_file"
  fi
  local targets_csv
  targets_csv="$(echo "$services" | paste -sd, -)"
  local ports
  ports="$(collect_host_ports "$resolved_file" "$targets_csv" | sort -u)"
  rm -f "$resolved_file"
  if [ -z "$ports" ]; then
    return 0
  fi
  local blocked=0
  while read -r p; do
    [ -z "$p" ] && continue
    if port_in_use "$p"; then
      echo "[start] 端口已被占用: $p (来自 $file)" >&2
      blocked=1
    fi
  done <<< "$ports"
  return $blocked
}

build_selected_services

check_ports_in_compose "$SCRIPT_DIR/docker-compose.yml" "$INFRA_SELECTED" || exit 1
check_ports_in_compose "$SCRIPT_DIR/apisix/docker-compose.yml" "$APISIX_SELECTED" || exit 1

$SUDO docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || \
  $SUDO docker network create "$NETWORK_NAME"

echo "[start] 启动 infra-base (project: $COMPOSE_PROJECT_NAME, network: $NETWORK_NAME)..."
cd "$SCRIPT_DIR"
if [ -n "$INFRA_SELECTED" ]; then
  if [ -f "$ENV_FILE" ]; then
    $COMPOSE_BIN --env-file "$ENV_FILE" up -d $INFRA_SELECTED
  else
    $COMPOSE_BIN up -d $INFRA_SELECTED
  fi
else
  echo "[start] 未选择 infra-base 容器，跳过 infra-base 启动"
fi

echo "[start] 启动 apisix (project: $COMPOSE_PROJECT_NAME)..."
cd "$SCRIPT_DIR/apisix"
if [ -n "$APISIX_SELECTED" ]; then
  if [ -f "$ENV_FILE" ]; then
    $COMPOSE_BIN --env-file "$ENV_FILE" up -d $APISIX_SELECTED
  else
    $COMPOSE_BIN up -d $APISIX_SELECTED
  fi
else
  echo "[start] 未选择 apisix 容器，跳过 apisix 启动"
fi
