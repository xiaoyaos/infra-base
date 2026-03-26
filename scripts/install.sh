#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib_project_env.sh"

MODE=""
PROJECT_NAME=""
BUNDLE_DIR="$BASE_DIR"
RESTORE_SOURCE=""
COMMON_PASSWORD="${COMMON_PASSWORD:-}"
ENV_FILE=""
SELECTED_PORTS=""
LAST_PORT=""
LAST_BOOL=""
REQUIRE_STRONG_PASSWORD="false"
PROJECT_ALREADY_EXISTS="false"
FORCE_RECREATE_SERVICES=""
PREVIOUS_INFRA_SELECTED=""
PREVIOUS_APISIX_SELECTED=""

usage() {
  cat <<'USAGE'
用法:
  sh scripts/install.sh [--mode base|full|restore] [--project <name>] [--bundle <path>] [--source raw|logical|1|2] [--password <pwd>] [--recreate <svc1,svc2>]

模式说明:
  --mode base     仅执行基础环境初始化并启动 infra-base
  --mode full     从零部署: 基础初始化 + (可用时)导入镜像 + 恢复数据 + 启动
  --mode restore  在现有环境上执行数据恢复

参数说明:
  --project       compose 项目名
  --bundle        迁移包目录(默认 infra-base 根目录)
  --source        恢复源(raw/logical 或 1/2)，不指定时按备份内容动态交互选择
  --password      统一密码(不传则交互输入，必填)
  --recreate      强制重建的服务列表，逗号分隔(仅已存在 project 时生效)

说明:
  - base/full 模式会逐项交互输入端口映射，默认使用容器官方端口
  - 每次回车采用默认值后，都会立即进行端口占用检查
  - 同一台机器做 full/restore 验证时，建议复制一份 infra-base 到独立目录后再执行
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="${2:-}"; shift 2 ;;
      --project|-p)
        PROJECT_NAME="${2:-}"; shift 2 ;;
      --bundle)
        BUNDLE_DIR="${2:-}"; shift 2 ;;
      --source)
        RESTORE_SOURCE="${2:-}"; shift 2 ;;
      --password)
        COMMON_PASSWORD="${2:-}"; shift 2 ;;
      --recreate)
        FORCE_RECREATE_SERVICES="${2:-}"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "[install] 未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

choose_mode_if_missing() {
  local input=""
  if [ -n "$MODE" ]; then
    return 0
  fi
  cat <<'EOF_MODE'
请选择执行模式（输入数字）:
  1) base    仅执行基础环境初始化并启动 infra-base
  2) full    从零部署: 基础初始化 + 导入镜像(如有) + 恢复数据 + 启动
  3) restore 在现有环境上执行数据恢复
EOF_MODE
  while :; do
    read -r -p "请输入选项 [1/2/3] (必填): " input
    case "$input" in
      1)
        MODE="base"
        return 0
        ;;
      2)
        MODE="full"
        return 0
        ;;
      3)
        MODE="restore"
        return 0
        ;;
      *)
        echo "[install] 模式无效，请输入 1、2 或 3" >&2
        ;;
    esac
  done
}

prompt_common_password() {
  if [ -z "$COMMON_PASSWORD" ]; then
    COMMON_PASSWORD="$(env_var_value "COMMON_PASSWORD")"
  fi
  if [ -n "$COMMON_PASSWORD" ]; then
    if [ "$REQUIRE_STRONG_PASSWORD" = "true" ] && ! password_meets_policy "$COMMON_PASSWORD"; then
      echo "[install] 统一密码长度必须大于等于 8，请重新输入" >&2
      COMMON_PASSWORD=""
    else
      return 0
    fi
  fi
  local input=""
  while :; do
    read -r -s -p "请输入统一密码(用于 pg/mongodb/minio，必填): " input
    echo
    if [ -n "$input" ]; then
      if [ "$REQUIRE_STRONG_PASSWORD" = "true" ] && ! password_meets_policy "$input"; then
        echo "[install] 统一密码长度必须大于等于 8，请重新输入" >&2
        continue
      fi
      COMMON_PASSWORD="$input"
      return 0
    fi
    echo "[install] 统一密码不能为空，请重新输入" >&2
  done
}

password_meets_policy() {
  local pwd="$1"
  [ "${#pwd}" -ge 8 ]
}

current_env_file() {
  if [ -n "$ENV_FILE" ]; then
    echo "$ENV_FILE"
  else
    legacy_env_file
  fi
}

env_var_value() {
  local key="$1"
  local env_file
  env_file="$(current_env_file)"
  if [ -f "$env_file" ]; then
    awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1); exit}' "$env_file"
  fi
}

env_bool_value() {
  local key="$1"
  local default="${2:-false}"
  local value
  value="$(env_var_value "$key")"
  case "$value" in
    true|TRUE|True|1|yes|YES|Yes) echo "true" ;;
    false|FALSE|False|0|no|NO|No) echo "false" ;;
    *) echo "$default" ;;
  esac
}

is_enabled() {
  local key="$1"
  [ "$(env_bool_value "$key" "false")" = "true" ]
}

prompt_env_password_if_missing() {
  local key="$1"
  local prompt="$2"
  local existing input

  existing="$(env_var_value "$key")"
  if [ -n "$existing" ]; then
    return 0
  fi

  while :; do
    read -r -s -p "$prompt" input
    echo
    if [ -z "$input" ]; then
      echo "[install] ${key} 不能为空，请重新输入" >&2
      continue
    fi
    set_env_var "$key" "$input"
    return 0
  done
}

ensure_redis_acl_passwords() {
  prompt_env_password_if_missing "APP_SUBSCRIBER_PASSWORD" "请输入 Redis app_subscriber 密码(必填): "
  prompt_env_password_if_missing "SOCKET_SUBSCRIBER_PASSWORD" "请输入 Redis socket_subscriber 密码(必填): "
}

prompt_raw_source_password() {
  local input=""
  while :; do
    read -r -s -p "请输入源环境统一密码(用于 raw 恢复后运行，必填): " input
    echo
    if [ -n "$input" ]; then
      if [ "$REQUIRE_STRONG_PASSWORD" = "true" ] && ! password_meets_policy "$input"; then
        echo "[install] 源环境统一密码长度必须大于等于 8，请重新输入" >&2
        continue
      fi
      COMMON_PASSWORD="$input"
      return 0
    fi
    echo "[install] 源环境统一密码不能为空，请重新输入" >&2
  done
}

resolve_password_for_source() {
  local source="$1"
  if [ "$source" = "raw" ]; then
    echo "[install] 提示: raw 恢复不支持指定新密码，必须使用源环境统一密码"
    prompt_raw_source_password
    return 0
  fi
  prompt_common_password
}

write_common_password_env() {
  set_env_var "COMMON_PASSWORD" "$COMMON_PASSWORD"
}

register_infra_base_env() {
  local profile_file="/etc/profile.d/custom.sh"
  local begin_mark="# >>> infra-base >>>"
  local end_mark="# <<< infra-base <<<"
  local tmp_file
  local sudo_cmd=""

  if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ] && [ -z "$sudo_cmd" ]; then
    echo "[install] 无法写入 $profile_file（当前非 root 且无 sudo），跳过全局变量注册" >&2
    return 0
  fi

  tmp_file="$(mktemp)"

  if [ -f "$profile_file" ]; then
    awk -v b="$begin_mark" -v e="$end_mark" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      skip!=1 {print}
    ' "$profile_file" > "$tmp_file"
  fi

  cat >> "$tmp_file" <<EOF_ENV
$begin_mark
export INFRA_BASE_HOME="$BASE_DIR"
case ":\$PATH:" in
  *":\$INFRA_BASE_HOME:"*) ;;
  *) export PATH="\$PATH:\$INFRA_BASE_HOME" ;;
esac
$end_mark
EOF_ENV

  $sudo_cmd mkdir -p /etc/profile.d
  $sudo_cmd cp "$tmp_file" "$profile_file"
  $sudo_cmd chmod 644 "$profile_file"
  rm -f "$tmp_file"

  echo "[install] 已写入全局变量: $profile_file (INFRA_BASE_HOME=$BASE_DIR)"
}

init_services_dir() {
  local services_dir="$BASE_DIR/services"
  local sudo_cmd=""

  mkdir -p "$services_dir"
  echo "[install] 已初始化目录: $services_dir"

  if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi

  if ! $sudo_cmd chown -R gitlab-runner:gitlab-runner "$services_dir" >/dev/null 2>&1; then
    echo "[install] 警告: 授权失败，已跳过 chown -R gitlab-runner:gitlab-runner $services_dir" >&2
  else
    echo "[install] 目录授权完成: gitlab-runner:gitlab-runner $services_dir"
  fi
}

set_env_var() {
  local key="$1"
  local val="$2"
  local env_file
  env_file="$(current_env_file)"
  mkdir -p "$(dirname "$env_file")"
  touch "$env_file"
  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "$env_file" && rm -f "$env_file.bak"
  else
    echo "${key}=${val}" >> "$env_file"
  fi
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

port_in_use_by_other_service() {
  local port="$1"
  local project="${2:-}"
  local service="${3:-}"

  if ! port_in_use "$port"; then
    return 1
  fi

  if [ -n "$project" ] && [ -n "$service" ] && command -v docker >/dev/null 2>&1; then
    local blockers
    blockers="$(docker ps \
      --filter "publish=$port" \
      --format '{{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.service"}}' 2>/dev/null || true)"
    if [ -n "$blockers" ]; then
      local only_self="true"
      while read -r blocker_project blocker_service; do
        [ -z "${blocker_project:-}" ] && continue
        if [ "$blocker_project" != "$project" ] || [ "$blocker_service" != "$service" ]; then
          only_self="false"
          break
        fi
      done <<< "$blockers"
      if [ "$only_self" = "true" ]; then
        return 1
      fi
    fi
  fi

  return 0
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

prompt_single_port() {
  local env_key="$1"
  local service_name="$2"
  local runtime_service="$3"
  local container_port="$4"
  local input=""
  local candidate=""
  local used_by=""
  local default_port=""

  default_port="$(env_var_value "$env_key")"
  default_port="${default_port:-$container_port}"

  while :; do
    read -r -p "请输入 ${service_name} 宿主机端口(容器端口 ${container_port}，默认 ${default_port}): " input
    candidate="${input:-$default_port}"

    if ! is_valid_port "$candidate"; then
      echo "[install] 端口无效: $candidate，请输入 1-65535 的整数" >&2
      continue
    fi

    used_by="$(echo "$SELECTED_PORTS" | tr ',' '\n' | awk -F: -v p="$candidate" '$1==p{print $2; exit}')"
    if [ -n "$used_by" ]; then
      echo "[install] 端口已被本次配置使用: $candidate (用于 $used_by)，请重新输入" >&2
      continue
    fi

    if port_in_use_by_other_service "$candidate" "$PROJECT_NAME" "$runtime_service"; then
      echo "[install] 端口已被系统占用: $candidate，请重新输入" >&2
      continue
    fi

    LAST_PORT="$candidate"
    if [ -z "$SELECTED_PORTS" ]; then
      SELECTED_PORTS="${candidate}:${service_name}"
    else
      SELECTED_PORTS="${SELECTED_PORTS},${candidate}:${service_name}"
    fi
    return 0
  done
}

prompt_enable_service() {
  local service_name="$1"
  local env_key="$2"
  local ans=""
  local current_default=""
  local prompt_suffix=""

  current_default="$(env_bool_value "$env_key" "true")"
  if [ "$current_default" = "true" ]; then
    prompt_suffix="[Y/n]"
  else
    prompt_suffix="[y/N]"
  fi
  while :; do
    read -r -p "是否创建 ${service_name}? ${prompt_suffix}: " ans
    if [ -z "$ans" ]; then
      if [ "$current_default" = "true" ]; then
        ans="Y"
      else
        ans="N"
      fi
    fi
    case "$ans" in
      Y|y)
        LAST_BOOL="true"
        return 0
        ;;
      N|n)
        LAST_BOOL="false"
        return 0
        ;;
      *)
        echo "[install] 请输入 Y 或 N" >&2
        ;;
    esac
  done
}

prompt_ports_for_base() {
  echo "[install] 请输入各服务端口(回车采用当前值或容器官方端口，均会校验占用):"

  SELECTED_PORTS=""
  echo "[install] 先选择是否创建容器，仅创建的容器才输入端口。"
  local etcd_enabled="false"

  prompt_enable_service "PostgreSQL(tsdb)" "ENABLE_TSDB"; set_env_var "ENABLE_TSDB" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "TSDB_PORT" "PostgreSQL(tsdb)" "tsdb" "5432"; set_env_var "TSDB_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "Redis(redis)" "ENABLE_REDIS"; set_env_var "ENABLE_REDIS" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    ensure_redis_acl_passwords
    prompt_single_port "REDIS_PORT" "Redis(redis)" "redis" "6379"; set_env_var "REDIS_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "Nginx(nginx)" "ENABLE_NGINX"; set_env_var "ENABLE_NGINX" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "NGINX_HTTPS_PORT" "Nginx HTTPS(nginx)" "nginx" "443"; set_env_var "NGINX_HTTPS_PORT" "$LAST_PORT"
    prompt_single_port "NGINX_HTTP_PORT" "Nginx HTTP(nginx)" "nginx" "80"; set_env_var "NGINX_HTTP_PORT" "$LAST_PORT"
    prompt_single_port "NGINX_HTTP_ALT_PORT" "Nginx HTTP-ALT(nginx)" "nginx" "3001"; set_env_var "NGINX_HTTP_ALT_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "MinIO(minio)" "ENABLE_MINIO"; set_env_var "ENABLE_MINIO" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "MINIO_API_PORT" "MinIO API(minio)" "minio" "9000"; set_env_var "MINIO_API_PORT" "$LAST_PORT"
    prompt_single_port "MINIO_CONSOLE_PORT" "MinIO Console(minio)" "minio" "9001"; set_env_var "MINIO_CONSOLE_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "EMQX(emqx)" "ENABLE_EMQX"; set_env_var "ENABLE_EMQX" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "EMQX_MQTT_PORT" "EMQX MQTT(emqx)" "emqx" "1883"; set_env_var "EMQX_MQTT_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_HTTP_API_PORT" "EMQX HTTP API(emqx)" "emqx" "8081"; set_env_var "EMQX_HTTP_API_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_WS_PORT" "EMQX WS(emqx)" "emqx" "8083"; set_env_var "EMQX_WS_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_SSL_MQTT_PORT" "EMQX SSL MQTT(emqx)" "emqx" "8883"; set_env_var "EMQX_SSL_MQTT_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_WSS_PORT" "EMQX WSS(emqx)" "emqx" "8084"; set_env_var "EMQX_WSS_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_DASHBOARD_PORT" "EMQX Dashboard(emqx)" "emqx" "18083"; set_env_var "EMQX_DASHBOARD_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "MongoDB(mongo)" "ENABLE_MONGO"; set_env_var "ENABLE_MONGO" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "MONGO_PORT" "MongoDB(mongo)" "mongo" "27017"; set_env_var "MONGO_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "etcd" "ENABLE_ETCD"; set_env_var "ENABLE_ETCD" "$LAST_BOOL"; etcd_enabled="$LAST_BOOL"

  prompt_enable_service "APISIX(apisix)" "ENABLE_APISIX"; set_env_var "ENABLE_APISIX" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ] && [ "$etcd_enabled" != "true" ]; then
    echo "[install] APISIX 依赖 etcd，已自动启用 etcd"
    set_env_var "ENABLE_ETCD" "true"
    etcd_enabled="true"
  fi

  prompt_enable_service "APISIX Dashboard(apisix-dashboard)" "ENABLE_APISIX_DASHBOARD"; set_env_var "ENABLE_APISIX_DASHBOARD" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "APISIX_DASHBOARD_PORT" "APISIX Dashboard" "apisix-dashboard" "9000"; set_env_var "APISIX_DASHBOARD_PORT" "$LAST_PORT"
  fi
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    return 1
  fi
}

choose_project_name() {
  local reuse_existing=""
  while :; do
    PROJECT_ALREADY_EXISTS="false"
    if [ -z "$PROJECT_NAME" ]; then
      read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
    fi
    if [ -z "$PROJECT_NAME" ]; then
      echo "[install] 项目名称不能为空，请重新输入" >&2
      continue
    fi
    if ! project_name_is_valid "$PROJECT_NAME"; then
      echo "[install] 项目名称仅支持字母、数字、点、下划线、中划线，且必须以字母或数字开头" >&2
      PROJECT_NAME=""
      continue
    fi
    if project_exists "$PROJECT_NAME"; then
      while :; do
        read -r -p "检测到项目 ${PROJECT_NAME} 已存在，是否对该项目执行补装/更新？ [Y/n]: " reuse_existing
        reuse_existing="${reuse_existing:-Y}"
        case "$reuse_existing" in
          Y|y)
            PROJECT_ALREADY_EXISTS="true"
            ENV_FILE="$(migrate_legacy_env_to_project "$PROJECT_NAME")"
            return 0
            ;;
          N|n)
            PROJECT_NAME=""
            break
            ;;
          *)
            echo "[install] 请输入 Y 或 N" >&2
            ;;
        esac
      done
      continue
    fi
    ensure_project_state_dir "$PROJECT_NAME"
    ENV_FILE="$(project_env_file "$PROJECT_NAME")"
    break
  done
}

project_exists() {
  local project="$1"
  if ! command -v docker >/dev/null 2>&1; then
    # Docker 尚未安装时无法检测项目是否存在，先视为不存在。
    return 1
  fi
  local count
  count="$(docker ps -a --filter "label=com.docker.compose.project=$project" -q | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ]
}

selected_service_strings() {
  local infra=""
  local apisix=""

  is_enabled "ENABLE_TSDB" && infra="$infra tsdb"
  is_enabled "ENABLE_REDIS" && infra="$infra redis"
  is_enabled "ENABLE_NGINX" && infra="$infra nginx"
  is_enabled "ENABLE_MINIO" && infra="$infra minio"
  is_enabled "ENABLE_EMQX" && infra="$infra emqx"
  is_enabled "ENABLE_MONGO" && infra="$infra mongo"
  is_enabled "ENABLE_ETCD" && apisix="$apisix etcd"
  is_enabled "ENABLE_APISIX" && apisix="$apisix apisix"
  is_enabled "ENABLE_APISIX_DASHBOARD" && apisix="$apisix apisix-dashboard"

  printf '%s\n%s\n' "$infra" "$apisix"
}

snapshot_selected_services() {
  local selected
  selected="$(selected_service_strings)"
  PREVIOUS_INFRA_SELECTED="$(printf '%s\n' "$selected" | sed -n '1p')"
  PREVIOUS_APISIX_SELECTED="$(printf '%s\n' "$selected" | sed -n '2p')"
}

known_service_name() {
  case "$1" in
    tsdb|redis|nginx|minio|emqx|mongo|etcd|apisix|apisix-dashboard) return 0 ;;
    *) return 1 ;;
  esac
}

service_enabled_by_name() {
  case "$1" in
    tsdb) is_enabled "ENABLE_TSDB" ;;
    redis) is_enabled "ENABLE_REDIS" ;;
    nginx) is_enabled "ENABLE_NGINX" ;;
    minio) is_enabled "ENABLE_MINIO" ;;
    emqx) is_enabled "ENABLE_EMQX" ;;
    mongo) is_enabled "ENABLE_MONGO" ;;
    etcd) is_enabled "ENABLE_ETCD" ;;
    apisix) is_enabled "ENABLE_APISIX" ;;
    apisix-dashboard) is_enabled "ENABLE_APISIX_DASHBOARD" ;;
    *) return 1 ;;
  esac
}

normalize_service_list() {
  local raw="${1:-}"
  echo "$raw" \
    | tr ',' '\n' \
    | tr ' ' '\n' \
    | sed '/^$/d' \
    | awk '!seen[$0]++'
}

prompt_recreate_services() {
  local requested=""
  local normalized=""
  local invalid=""
  local disabled=""
  local valid=""

  if [ "$PROJECT_ALREADY_EXISTS" != "true" ]; then
    FORCE_RECREATE_SERVICES=""
    return 0
  fi

  while :; do
    invalid=""
    disabled=""
    valid=""

    if [ -n "$FORCE_RECREATE_SERVICES" ]; then
      requested="$FORCE_RECREATE_SERVICES"
    else
      echo "[install] 如需强制重建已存在服务，请输入服务名(逗号/空格分隔，直接回车跳过)"
      echo "[install] 可选服务: tsdb redis nginx minio emqx mongo etcd apisix apisix-dashboard"
      read -r -p "请输入需要强制重建的服务: " requested
    fi

    normalized="$(normalize_service_list "$requested")"
    if [ -z "$normalized" ]; then
      FORCE_RECREATE_SERVICES=""
      return 0
    fi

    while read -r svc; do
      [ -z "$svc" ] && continue
      if ! known_service_name "$svc"; then
        invalid="$invalid $svc"
        continue
      fi
      if ! service_enabled_by_name "$svc"; then
        disabled="$disabled $svc"
        continue
      fi
      if [ -z "$valid" ]; then
        valid="$svc"
      else
        valid="$valid,$svc"
      fi
    done <<< "$normalized"

    if [ -n "$invalid" ]; then
      echo "[install] 存在未知服务:$invalid" >&2
      if [ -n "$FORCE_RECREATE_SERVICES" ]; then
        exit 1
      fi
      continue
    fi
    if [ -n "$disabled" ]; then
      echo "[install] 以下服务当前未启用，不能强制重建:$disabled" >&2
      if [ -n "$FORCE_RECREATE_SERVICES" ]; then
        exit 1
      fi
      continue
    fi

    FORCE_RECREATE_SERVICES="$valid"
    return 0
  done
}

service_list_diff() {
  local old_list="${1:-}"
  local new_list="${2:-}"

  echo "$old_list" | xargs -n1 2>/dev/null \
    | awk 'NF' \
    | while read -r svc; do
        echo "$new_list" | tr ' ' '\n' | awk 'NF' | grep -Fx "$svc" >/dev/null 2>&1 || echo "$svc"
      done
}

remove_services_from_compose() {
  local file="$1"
  shift || true
  [ "$#" -eq 0 ] && return 0

  local compose
  compose="$(compose_cmd)" || return 0

  echo "[install] 停止并移除已取消选择的服务: $*"
  if [ -f "$ENV_FILE" ]; then
    $compose --env-file "$ENV_FILE" -f "$file" stop "$@" >/dev/null 2>&1 || true
    $compose --env-file "$ENV_FILE" -f "$file" rm -f "$@" >/dev/null 2>&1 || true
  else
    $compose -f "$file" stop "$@" >/dev/null 2>&1 || true
    $compose -f "$file" rm -f "$@" >/dev/null 2>&1 || true
  fi
}

prune_disabled_services() {
  [ "$PROJECT_ALREADY_EXISTS" = "true" ] || return 0

  local selected
  local current_infra
  local current_apisix
  local removed_infra=()
  local removed_apisix=()
  local svc

  selected="$(selected_service_strings)"
  current_infra="$(printf '%s\n' "$selected" | sed -n '1p')"
  current_apisix="$(printf '%s\n' "$selected" | sed -n '2p')"

  while read -r svc; do
    [ -z "$svc" ] && continue
    removed_infra+=("$svc")
  done < <(service_list_diff "$PREVIOUS_INFRA_SELECTED" "$current_infra")

  while read -r svc; do
    [ -z "$svc" ] && continue
    removed_apisix+=("$svc")
  done < <(service_list_diff "$PREVIOUS_APISIX_SELECTED" "$current_apisix")

  if [ ${#removed_infra[@]} -gt 0 ]; then
    remove_services_from_compose "$BASE_DIR/docker-compose.yml" "${removed_infra[@]}"
  fi
  if [ ${#removed_apisix[@]} -gt 0 ]; then
    remove_services_from_compose "$BASE_DIR/apisix/docker-compose.yml" "${removed_apisix[@]}"
  fi
}

install_docker_and_runtime() {
  # 检查系统版本
  local os_version
  os_version="$(grep -oP '^PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || true)"
  local os_id
  os_id="$(. /etc/os-release && echo "${ID:-}")"
  local os_major
  os_major="$(. /etc/os-release && echo "${VERSION_ID:-}" | cut -d. -f1)"
  local pkg_mgr="yum"
  if command -v dnf >/dev/null 2>&1; then
    pkg_mgr="dnf"
  fi

  case "$os_id" in
    rocky)
      echo "当前为 Rocky 系统: $os_version"
      ;;
    centos)
      echo "当前为 CentOS 系统: $os_version"
      ;;
    ubuntu)
      echo "当前为 Ubuntu 系统: $os_version"
      ;;
    *)
      echo "不支持的操作系统: $os_version"
      echo "脚本退出"
      exit 1
      ;;
  esac

  if command -v docker >/dev/null 2>&1; then
    echo 'Docker is installed.'
    echo "Docker version: $(docker --version)"
  else
    echo 'Docker is not installed.'
    if [[ "$os_version" == *"CentOS"* || "$os_version" == *"Rocky"* ]]; then
      sudo "$pkg_mgr" remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true

      # 根据系统主版本动态写入 Docker CE 源，避免 Rocky/CentOS 9 误用 el7 包。
      local repo_major="$os_major"
      if [ -z "$repo_major" ]; then
        repo_major="7"
      fi
      if [ "$repo_major" != "7" ] && [ "$repo_major" != "8" ] && [ "$repo_major" != "9" ]; then
        repo_major="7"
      fi

      sudo tee /etc/yum.repos.d/docker-ce.repo >/dev/null <<'EOF_DOCKER_REPO'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/__MAJOR__/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF_DOCKER_REPO
      sudo sed -i "s/__MAJOR__/${repo_major}/g" /etc/yum.repos.d/docker-ce.repo

      if [ "$pkg_mgr" = "dnf" ]; then
        sudo dnf makecache --refresh || true
      else
        sudo yum makecache fast || true
      fi

      if ! sudo "$pkg_mgr" -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        echo "[install] 首次安装失败，尝试 --nobest 重试..."
        sudo "$pkg_mgr" -y install --nobest docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      fi
    else
      for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        sudo apt-get remove -y "$pkg" || true
      done
      sudo apt-get update
      sudo apt-get -y install ca-certificates curl
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      sudo chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update
      sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    sudo systemctl enable --now docker
  fi

  if [ -f "$BASE_DIR/dockerx/docker-x" ]; then
    mkdir -p "$HOME/.docker/cli-plugins"
    cp "$BASE_DIR/dockerx/docker-x" "$HOME/.docker/cli-plugins/docker-x"
    chmod +x "$HOME/.docker/cli-plugins/docker-x"
    echo "[install] 已安装 docker-x 到 $HOME/.docker/cli-plugins/docker-x"
    echo "[install] 可使用: docker x ps / docker x logs"
  else
    echo "[install] 未找到 ./dockerx/docker-x，跳过安装 docker-x"
  fi

  if [ -f "$BASE_DIR/dockerx/docker-ps" ]; then
    sudo cp "$BASE_DIR/dockerx/docker-ps" /usr/local/bin/docker-ps
    sudo chmod +x /usr/local/bin/docker-ps
    echo "[install] 已安装 docker-ps 兼容命令（内部转发到 docker-x）"
  else
    echo "[install] 未找到 ./dockerx/docker-ps，跳过安装 docker-ps"
  fi

  sudo mkdir -p /etc/docker
  if [ -e /etc/docker/daemon.json ]; then
    sudo mv /etc/docker/daemon.json /etc/docker/daemon.json.bak
  else
    echo 'daemon.json does not exist.'
  fi
  sudo cp "$BASE_DIR/docker_daemon.json" /etc/docker/daemon.json

  read -r -p "是否重启 Docker 以使 daemon.json 生效? (y/N): " RESTART_DOCKER
  if [[ "$RESTART_DOCKER" =~ ^[Yy]$ ]]; then
    echo Restart docker...
    sudo systemctl daemon-reload
    sudo systemctl restart docker
  else
    echo "已跳过重启 Docker，daemon.json 变更需重启后生效"
  fi
}

load_images_from_bundle() {
  local image_tar="$BUNDLE_DIR/images/all-images.tar"
  if [ -f "$image_tar" ]; then
    echo "[install] 检测到离线镜像包: $image_tar"
    read -r -p "是否导入离线镜像? (Y/n): " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      docker load -i "$image_tar"
    fi
  else
    echo "[install] 未发现离线镜像包，跳过导入"
  fi
}

validate_bundle_dir() {
  if [ ! -d "$BUNDLE_DIR" ]; then
    echo "[install] bundle 目录不存在: $BUNDLE_DIR" >&2
    exit 1
  fi

  if [ ! -f "$BUNDLE_DIR/manifest.json" ]; then
    echo "[install] 无效迁移包: 缺少 manifest.json ($BUNDLE_DIR/manifest.json)" >&2
    echo "[install] 请先执行: sh infractl.sh ，选择 2) 生成迁移包（migration backup），再使用 full/restore" >&2
    exit 1
  fi

  if [ ! -d "$BUNDLE_DIR/production_data" ] && [ ! -d "$BUNDLE_DIR/data/logical" ]; then
    echo "[install] 无效迁移包: 未找到可恢复数据目录(production_data 或 data/logical)" >&2
    exit 1
  fi
}

run_restore() {
  if [ ! -x "$BASE_DIR/scripts/restore.sh" ]; then
    echo "[install] 未找到 restore.sh: $BASE_DIR/scripts/restore.sh" >&2
    exit 1
  fi

  if [ -n "$PROJECT_NAME" ] && [ -n "$RESTORE_SOURCE" ]; then
    "$BASE_DIR/scripts/restore.sh" --bundle "$BUNDLE_DIR" --password "$COMMON_PASSWORD" --skip-images --project "$PROJECT_NAME" --source "$RESTORE_SOURCE"
  elif [ -n "$PROJECT_NAME" ]; then
    "$BASE_DIR/scripts/restore.sh" --bundle "$BUNDLE_DIR" --password "$COMMON_PASSWORD" --skip-images --project "$PROJECT_NAME"
  elif [ -n "$RESTORE_SOURCE" ]; then
    "$BASE_DIR/scripts/restore.sh" --bundle "$BUNDLE_DIR" --password "$COMMON_PASSWORD" --skip-images --source "$RESTORE_SOURCE"
  else
    "$BASE_DIR/scripts/restore.sh" --bundle "$BUNDLE_DIR" --password "$COMMON_PASSWORD" --skip-images
  fi
}

sync_dir_contents() {
  local src="$1"
  local dst="$2"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src/" "$dst/"
  else
    rm -rf "$dst"
    mkdir -p "$dst"
    tar -C "$src" -cf - . | tar -C "$dst" -xf -
  fi
}

restore_services_dir() {
  local src="$BUNDLE_DIR/services"
  local dst="$BASE_DIR/services"
  if [ ! -d "$src" ]; then
    echo "[install] 未找到 services 备份目录，跳过恢复: $src"
    return 0
  fi

  echo "[install] 恢复 services 目录: $src -> $dst"
  mkdir -p "$dst"
  sync_dir_contents "$src" "$dst"
}

normalize_restore_source() {
  case "$RESTORE_SOURCE" in
    1|raw|RAW|Raw) RESTORE_SOURCE="raw" ;;
    2|logical|LOGICAL|Logical) RESTORE_SOURCE="logical" ;;
    "") ;;
    *)
      echo "[install] 无效的恢复源: $RESTORE_SOURCE (仅支持 raw/logical/1/2)" >&2
      exit 1
      ;;
  esac
}

detect_restore_source_mode() {
  local has_raw="false"
  local has_logical="false"
  [ -d "$BUNDLE_DIR/production_data" ] && has_raw="true"
  [ -d "$BUNDLE_DIR/data/raw/production_data" ] && has_raw="true"
  if [ -f "$BUNDLE_DIR/data/logical/pg_dumpall.sql" ] || \
     [ -f "$BUNDLE_DIR/data/logical/pg/globals.sql" ] || \
     [ -f "$BUNDLE_DIR/data/logical/mongo.archive.gz" ] || \
     [ -d "$BUNDLE_DIR/data/logical/minio" ]; then
    has_logical="true"
  fi

  if [ "$has_raw" = "false" ] && [ "$has_logical" = "false" ]; then
    echo "[install] 未检测到可恢复数据(raw/logical 都不存在)" >&2
    exit 1
  fi

  if [ "$has_raw" = "true" ] && [ "$has_logical" = "false" ]; then
    while :; do
      read -r -p "检测到仅 raw 可用。请输入选项 [1]，默认 1(raw): " ans
      ans="${ans:-1}"
      case "$ans" in
        1) RESTORE_SOURCE="raw"; return ;;
        *) echo "[install] 无效选项，仅支持 1" >&2 ;;
      esac
    done
  fi

  if [ "$has_raw" = "false" ] && [ "$has_logical" = "true" ]; then
    while :; do
      read -r -p "检测到仅 logical 可用。请输入选项 [2]，默认 2(logical): " ans
      ans="${ans:-2}"
      case "$ans" in
        2) RESTORE_SOURCE="logical"; return ;;
        *) echo "[install] 无效选项，仅支持 2" >&2 ;;
      esac
    done
  fi

  cat <<'EOF_MENU'
检测到 raw 与 logical 同时可用：
  1) raw      (不支持指定新密码，需输入源环境统一密码)
  2) logical  (可按当前环境输入统一密码)
EOF_MENU
  while :; do
    read -r -p "请输入选项 [1/2]，默认 2(logical): " ans
    ans="${ans:-2}"
    case "$ans" in
      1) RESTORE_SOURCE="raw"; return ;;
      2) RESTORE_SOURCE="logical"; return ;;
      *) echo "[install] 无效选项，请输入 1 或 2" >&2 ;;
    esac
  done
}

print_same_host_restore_notice() {
  cat <<EOF_NOTICE
[install] 提示:
  - full/restore 会把数据恢复到当前 infra-base 目录下
  - 如果在同一台机器上做迁移验证，建议先复制一份 infra-base 到独立目录后再执行
  - 迁移包目录可单独放置，通过 --bundle 指向即可，不要求与当前目录相同
EOF_NOTICE
}

main() {
  parse_args "$@"
  choose_mode_if_missing

  if [ -n "$PROJECT_NAME" ]; then
    if ! project_name_is_valid "$PROJECT_NAME"; then
      echo "[install] 非法项目名称: $PROJECT_NAME" >&2
      exit 1
    fi
    ENV_FILE="$(resolve_project_env_file "$PROJECT_NAME")"
  fi

  case "$MODE" in
    base)
      REQUIRE_STRONG_PASSWORD="true"
      choose_project_name
      snapshot_selected_services
      prompt_common_password
      write_common_password_env
      prompt_ports_for_base
      prompt_recreate_services
      install_docker_and_runtime
      register_infra_base_env
      init_services_dir
      prune_disabled_services
      echo "[install] 安装完成，准备启动 infra-base..."
      if [ -n "$FORCE_RECREATE_SERVICES" ]; then
        bash "$BASE_DIR/scripts/start.sh" --project "$PROJECT_NAME" --recreate "$FORCE_RECREATE_SERVICES"
      else
        bash "$BASE_DIR/scripts/start.sh" --project "$PROJECT_NAME"
      fi
      ;;

    full)
      REQUIRE_STRONG_PASSWORD="true"
      choose_project_name
      snapshot_selected_services
      validate_bundle_dir
      print_same_host_restore_notice
      prompt_common_password
      write_common_password_env
      prompt_ports_for_base
      prompt_recreate_services
      install_docker_and_runtime
      register_infra_base_env
      init_services_dir
      load_images_from_bundle

      if [ -z "$RESTORE_SOURCE" ]; then
        detect_restore_source_mode
      fi
      normalize_restore_source
      resolve_password_for_source "$RESTORE_SOURCE"
      write_common_password_env
      prune_disabled_services

      if [ "$RESTORE_SOURCE" = "raw" ]; then
        run_restore
        echo "[install] 恢复完成，准备启动 infra-base..."
        if [ -n "$FORCE_RECREATE_SERVICES" ]; then
          bash "$BASE_DIR/scripts/start.sh" --project "$PROJECT_NAME" --recreate "$FORCE_RECREATE_SERVICES"
        else
          bash "$BASE_DIR/scripts/start.sh" --project "$PROJECT_NAME"
        fi
      elif [ "$RESTORE_SOURCE" = "logical" ]; then
        echo "[install] 先启动 infra-base，再执行 logical 恢复..."
        if [ -n "$FORCE_RECREATE_SERVICES" ]; then
          bash "$BASE_DIR/scripts/start.sh" --project "$PROJECT_NAME" --recreate "$FORCE_RECREATE_SERVICES"
        else
          bash "$BASE_DIR/scripts/start.sh" --project "$PROJECT_NAME"
        fi
        run_restore
      else
        echo "[install] 无效的恢复源: $RESTORE_SOURCE" >&2
        exit 1
      fi
      restore_services_dir
      ;;

    restore)
      validate_bundle_dir
      print_same_host_restore_notice
      if [ -z "$RESTORE_SOURCE" ]; then
        detect_restore_source_mode
      fi
      normalize_restore_source
      resolve_password_for_source "$RESTORE_SOURCE"
      write_common_password_env
      run_restore
      ;;

    *)
      echo "[install] 不支持的 mode: $MODE" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
