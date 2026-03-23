#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
  cat <<'USAGE'
用法:
  ./deploy_services.sh -p <项目名> -n <网络名> -f <compose文件> [-f <compose文件> ...]

示例:
  ./deploy_services.sh -p demo -n infra-base-<项目名> -f /path/to/order/docker-compose.yml -f /path/to/device/docker-compose.yml

说明:
  - 会创建指定网络(如不存在)
  - 会为每个 compose 文件执行 docker compose up -d
  - 会导出 COMPOSE_PROJECT_NAME=<项目名> 与 NETWORK_NAME=<网络名>
    业务 compose 可通过 ${NETWORK_NAME} 引用外部网络
USAGE
}

PROJECT_NAME=""
NETWORK_NAME=""
COMPOSE_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)
      PROJECT_NAME="${2:-}"; shift 2 ;;
    -n|--network)
      NETWORK_NAME="${2:-}"; shift 2 ;;
    -f|--file)
      COMPOSE_FILES+=("${2:-}"); shift 2 ;;
    -h|--help)
      print_usage; exit 0 ;;
    *)
      echo "[deploy] 未知参数: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

if [ -z "$PROJECT_NAME" ]; then
  read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
fi
if [ -z "$PROJECT_NAME" ]; then
  echo "[deploy] 项目名称不能为空" >&2
  exit 1
fi

if [ -z "$NETWORK_NAME" ]; then
  NETWORK_NAME="infra-base-${PROJECT_NAME}"
fi

if [ ${#COMPOSE_FILES[@]} -eq 0 ]; then
  echo "[deploy] 至少需要一个 compose 文件 (-f)" >&2
  print_usage
  exit 1
fi

SUDO=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[deploy] 未找到 docker" >&2
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
  echo "[deploy] 未检测到 docker compose" >&2
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

changed_services_for_compose() {
  local file="$1"
  local services hashes
  services="$($COMPOSE_BIN -f "$file" config --services 2>/dev/null || true)"
  if [ -z "$services" ]; then
    echo "__ALL__"
    return 0
  fi
  hashes="$(echo "$services" | while read -r s; do
    [ -z "$s" ] && continue
    $COMPOSE_BIN -f "$file" config --hash "$s" 2>/dev/null
  done)"
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
  local services
  services="$(changed_services_for_compose "$file")"
  if [ "$services" = "__ALL__" ]; then
    services="$($COMPOSE_BIN -f "$file" config --services 2>/dev/null || true)"
  fi
  if [ -z "$services" ]; then
    echo "[deploy] 未检测到需要变更的服务，跳过端口检查: $file"
    return 0
  fi
  local targets_csv
  targets_csv="$(echo "$services" | paste -sd, -)"
  local ports
  ports="$(collect_host_ports "$file" "$targets_csv" | sort -u)"
  if [ -z "$ports" ]; then
    return 0
  fi
  local blocked=0
  while read -r p; do
    [ -z "$p" ] && continue
    if port_in_use "$p"; then
      echo "[deploy] 端口已被占用: $p (来自 $file)" >&2
      blocked=1
    fi
  done <<< "$ports"
  return $blocked
}

export COMPOSE_PROJECT_NAME="$PROJECT_NAME"
export NETWORK_NAME="$NETWORK_NAME"

$SUDO docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || \
  $SUDO docker network create "$NETWORK_NAME"

echo "[deploy] 使用项目名: $COMPOSE_PROJECT_NAME"
echo "[deploy] 使用网络: $NETWORK_NAME"

for f in "${COMPOSE_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "[deploy] compose 文件不存在: $f" >&2
    exit 1
  fi
done

for f in "${COMPOSE_FILES[@]}"; do
  check_ports_in_compose "$f" || exit 1
done

for f in "${COMPOSE_FILES[@]}"; do
  echo "[deploy] 启动服务: $f"
  $COMPOSE_BIN -f "$f" up -d
done

echo "[deploy] 完成"
