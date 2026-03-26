#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib_project_env.sh"

ENV_FILE=""
INFRA_SELECTED=""
APISIX_SELECTED=""
RECREATE_SERVICES=""

usage() {
  cat <<'USAGE'
用法:
  sh scripts/start.sh [--project <name>] [--recreate <svc1,svc2>]

说明:
  --project   compose 项目名（不传则交互输入）
  --recreate  强制重建的服务列表，逗号分隔
USAGE
}

PROJECT_NAME=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project|-p)
        PROJECT_NAME="${2:-}"; shift 2 ;;
      --recreate)
        RECREATE_SERVICES="${2:-}"; shift 2 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [ -z "$PROJECT_NAME" ]; then
          PROJECT_NAME="$1"
          shift
        else
          echo "[start] 未知参数: $1" >&2
          usage
          exit 1
        fi
        ;;
    esac
  done
}

parse_args "$@"

if [ -z "$PROJECT_NAME" ]; then
  read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
fi
if [ -z "$PROJECT_NAME" ]; then
  echo "[start] 项目名称不能为空" >&2
  exit 1
fi
if ! project_name_is_valid "$PROJECT_NAME"; then
  echo "[start] 非法项目名称: $PROJECT_NAME" >&2
  exit 1
fi

ENV_FILE="$(resolve_project_env_file "$PROJECT_NAME")"

export COMPOSE_PROJECT_NAME="$PROJECT_NAME"
export NETWORK_NAME="${NETWORK_NAME:-infra-base-${COMPOSE_PROJECT_NAME}}"

echo "[start] 生成服务端口清单..."
"$BASE_DIR/scripts/generate_services.sh"

SUDO=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[start] 未找到 docker，请先运行 infractl.sh" >&2
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

normalize_service_list_csv() {
  local raw="${1:-}"
  local normalized

  normalized="$(
    echo "$raw" \
      | tr ',' '\n' \
      | tr ' ' '\n' \
      | sed '/^$/d' \
      | awk '!seen[$0]++'
  )"

  if [ -z "$normalized" ]; then
    echo ""
  else
    echo "$normalized" | paste -sd, -
  fi
}

csv_contains() {
  local csv="${1:-}"
  local target="${2:-}"
  [ -n "$csv" ] || return 1
  echo "$csv" | tr ',' '\n' | grep -Fx "$target" >/dev/null 2>&1
}

service_string_to_csv() {
  local services="${1:-}"
  if [ -z "$services" ]; then
    echo ""
  else
    echo "$services" | xargs -n1 2>/dev/null | awk 'NF' | paste -sd, -
  fi
}

filter_services_by_csv() {
  local services="${1:-}"
  local csv="${2:-}"

  if [ -z "$services" ] || [ -z "$csv" ]; then
    return 0
  fi

  while read -r svc; do
    [ -z "$svc" ] && continue
    csv_contains "$csv" "$svc" && echo "$svc"
  done <<< "$(echo "$services" | xargs -n1 2>/dev/null)"

  return 0
}

port_in_use_by_blocker() {
  local port="$1"
  local allowed_services_csv="${2:-}"

  if ! port_in_use "$port"; then
    return 1
  fi

  local blockers
  blockers="$(docker ps \
    --filter "publish=$port" \
    --format '{{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.service"}}' 2>/dev/null || true)"

  if [ -z "$blockers" ]; then
    return 0
  fi

  while read -r blocker_project blocker_service; do
    [ -z "${blocker_project:-}" ] && continue
    if [ "$blocker_project" = "$COMPOSE_PROJECT_NAME" ] && csv_contains "$allowed_services_csv" "$blocker_service"; then
      continue
    fi
    return 0
  done <<< "$blockers"

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

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

render_redis_config() {
  if ! is_enabled "ENABLE_REDIS"; then
    return 0
  fi

  local pwd
  pwd="$(env_value "COMMON_PASSWORD" "")"
  local app_sub_pwd
  app_sub_pwd="$(env_value "APP_SUBSCRIBER_PASSWORD" "app_subscriber_password")"
  local socket_sub_pwd
  socket_sub_pwd="$(env_value "SOCKET_SUBSCRIBER_PASSWORD" "socket_subscriber_password")"
  if [ -z "$pwd" ]; then
    echo "[start] 缺少 COMMON_PASSWORD，无法渲染 Redis 配置" >&2
    return 1
  fi

  local redis_dir="$BASE_DIR/config/redis"
  local conf_tpl="$redis_dir/redis.conf.template"
  local acl_tpl="$redis_dir/users.acl.template"
  local conf_out="$redis_dir/redis.conf"
  local acl_out="$redis_dir/users.acl"
  local escaped
  local escaped_app_sub_pwd
  local escaped_socket_sub_pwd

  if [ ! -f "$conf_tpl" ] || [ ! -f "$acl_tpl" ]; then
    echo "[start] 缺少 Redis 模板文件: $conf_tpl 或 $acl_tpl" >&2
    return 1
  fi

  mkdir -p "$redis_dir"
  escaped="$(escape_sed_replacement "$pwd")"
  escaped_app_sub_pwd="$(escape_sed_replacement "$app_sub_pwd")"
  escaped_socket_sub_pwd="$(escape_sed_replacement "$socket_sub_pwd")"
  sed "s|__COMMON_PASSWORD__|$escaped|g" "$conf_tpl" > "$conf_out"
  sed -e "s|__COMMON_PASSWORD__|$escaped|g" \
      -e "s|__APP_SUBSCRIBER_PASSWORD__|$escaped_app_sub_pwd|g" \
      -e "s|__SOCKET_SUBSCRIBER_PASSWORD__|$escaped_socket_sub_pwd|g" \
      "$acl_tpl" > "$acl_out"
  if awk 'NF && $1 != "user" { exit 1 }' "$acl_out"; then
    :
  else
    echo "[start] Redis ACL 文件不合法：非空行必须以 user 开头，请检查 $acl_tpl" >&2
    return 1
  fi
  chmod 600 "$acl_out" >/dev/null 2>&1 || true
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

validate_recreate_services() {
  local normalized
  local all_selected
  local invalid=""
  local svc

  normalized="$(normalize_service_list_csv "$RECREATE_SERVICES")"
  RECREATE_SERVICES="$normalized"
  [ -n "$RECREATE_SERVICES" ] || return 0

  all_selected="$(service_string_to_csv "$INFRA_SELECTED $APISIX_SELECTED")"
  while read -r svc; do
    [ -z "$svc" ] && continue
    if ! csv_contains "$all_selected" "$svc"; then
      invalid="$invalid $svc"
    fi
  done <<< "$(echo "$RECREATE_SERVICES" | tr ',' '\n')"

  if [ -n "$invalid" ]; then
    echo "[start] 以下服务当前未启用，不能强制重建:$invalid" >&2
    exit 1
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
    services="$(echo "$forced_services" | tr ' ' '\n' | sed '/^$/d')"
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
    if port_in_use_by_blocker "$p" "$targets_csv"; then
      echo "[start] 端口已被占用: $p (来自 $file)" >&2
      blocked=1
    fi
  done <<< "$ports"
  return $blocked
}

compose_up_services() {
  local workdir="$1"
  local compose_file="$2"
  local services="$3"
  local recreate_csv="$4"
  local recreate_services=""
  local normal_services=""
  local svc

  [ -n "$services" ] || return 0

  recreate_services="$(filter_services_by_csv "$services" "$recreate_csv" | paste -sd' ' -)"

  cd "$workdir"
  while read -r svc; do
    [ -z "$svc" ] && continue
    if ! csv_contains "$recreate_csv" "$svc"; then
      if [ -z "$normal_services" ]; then
        normal_services="$svc"
      else
        normal_services="$normal_services $svc"
      fi
    fi
  done <<< "$(echo "$services" | tr ' ' '\n' | sed '/^$/d')"

  if [ -n "$normal_services" ]; then
    if [ -f "$ENV_FILE" ]; then
      $COMPOSE_BIN --env-file "$ENV_FILE" -f "$compose_file" up -d $normal_services
    else
      $COMPOSE_BIN -f "$compose_file" up -d $normal_services
    fi
  fi

  if [ -n "$recreate_services" ]; then
    if [ -f "$ENV_FILE" ]; then
      $COMPOSE_BIN --env-file "$ENV_FILE" -f "$compose_file" up -d --force-recreate $recreate_services
    else
      $COMPOSE_BIN -f "$compose_file" up -d --force-recreate $recreate_services
    fi
  fi
}

build_selected_services
validate_recreate_services

render_redis_config || exit 1

check_ports_in_compose "$BASE_DIR/docker-compose.yml" "$INFRA_SELECTED" || exit 1
check_ports_in_compose "$BASE_DIR/apisix/docker-compose.yml" "$APISIX_SELECTED" || exit 1

$SUDO docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || \
  $SUDO docker network create "$NETWORK_NAME"

echo "[start] 启动 infra-base (project: $COMPOSE_PROJECT_NAME, network: $NETWORK_NAME)..."
if [ -n "$INFRA_SELECTED" ]; then
  compose_up_services "$BASE_DIR" "$BASE_DIR/docker-compose.yml" "$INFRA_SELECTED" "$RECREATE_SERVICES"
else
  echo "[start] 未选择 infra-base 容器，跳过 infra-base 启动"
fi

echo "[start] 启动 apisix (project: $COMPOSE_PROJECT_NAME)..."
if [ -n "$APISIX_SELECTED" ]; then
  compose_up_services "$BASE_DIR/apisix" "$BASE_DIR/apisix/docker-compose.yml" "$APISIX_SELECTED" "$RECREATE_SERVICES"
else
  echo "[start] 未选择 apisix 容器，跳过 apisix 启动"
fi
