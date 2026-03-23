#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=""
PROJECT_NAME=""
BUNDLE_DIR="$SCRIPT_DIR"
RESTORE_SOURCE=""
COMMON_PASSWORD="${COMMON_PASSWORD:-}"
SELECTED_PORTS=""
LAST_PORT=""
LAST_BOOL=""

usage() {
  cat <<'USAGE'
用法:
  sh install.sh [--mode base|full|restore] [--project <name>] [--bundle <path>] [--source raw|logical|1|2] [--password <pwd>]

模式说明:
  --mode base     仅执行基础环境初始化并启动 infra-base
  --mode full     从零部署: 基础初始化 + (可用时)导入镜像 + 恢复数据 + 启动
  --mode restore  在现有环境上执行数据恢复

参数说明:
  --project       compose 项目名
  --bundle        迁移包目录(默认当前目录)
  --source        恢复源(raw/logical 或 1/2)，不指定时按备份内容动态交互选择
  --password      统一密码(不传则交互输入，必填)

说明:
  - base/full 模式会逐项交互输入端口映射，默认使用容器官方端口
  - 每次回车采用默认值后，都会立即进行端口占用检查
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
  if [ -n "$COMMON_PASSWORD" ]; then
    return 0
  fi
  local input=""
  while :; do
    read -r -s -p "请输入统一密码(用于 pg/mongodb/minio，必填): " input
    echo
    if [ -n "$input" ]; then
      COMMON_PASSWORD="$input"
      return 0
    fi
    echo "[install] 统一密码不能为空，请重新输入" >&2
  done
}

write_common_password_env() {
  set_env_var "COMMON_PASSWORD" "$COMMON_PASSWORD"
}

set_env_var() {
  local key="$1"
  local val="$2"
  local env_file="$SCRIPT_DIR/.env"
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

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

prompt_single_port() {
  local env_key="$1"
  local service_name="$2"
  local container_port="$3"
  local input=""
  local candidate=""
  local used_by=""

  while :; do
    read -r -p "请输入 ${service_name} 宿主机端口(容器端口 ${container_port}，默认 ${container_port}): " input
    candidate="${input:-$container_port}"

    if ! is_valid_port "$candidate"; then
      echo "[install] 端口无效: $candidate，请输入 1-65535 的整数" >&2
      continue
    fi

    used_by="$(echo "$SELECTED_PORTS" | tr ',' '\n' | awk -F: -v p="$candidate" '$1==p{print $2; exit}')"
    if [ -n "$used_by" ]; then
      echo "[install] 端口已被本次配置使用: $candidate (用于 $used_by)，请重新输入" >&2
      continue
    fi

    if port_in_use "$candidate"; then
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

prompt_ports_for_base() {
  echo "[install] 请输入各服务端口(回车采用容器官方端口，均会校验占用):"

  SELECTED_PORTS=""
  echo "[install] 先选择是否创建容器(默认创建)，仅创建的容器才输入端口。"
  local etcd_enabled="false"

  prompt_enable_service "PostgreSQL(tsdb)"; set_env_var "ENABLE_TSDB" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "TSDB_PORT" "PostgreSQL(tsdb)" "5432"; set_env_var "TSDB_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "Redis(redis)"; set_env_var "ENABLE_REDIS" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "REDIS_PORT" "Redis(redis)" "6379"; set_env_var "REDIS_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "Nginx(nginx)"; set_env_var "ENABLE_NGINX" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "NGINX_HTTPS_PORT" "Nginx HTTPS(nginx)" "443"; set_env_var "NGINX_HTTPS_PORT" "$LAST_PORT"
    prompt_single_port "NGINX_HTTP_PORT" "Nginx HTTP(nginx)" "80"; set_env_var "NGINX_HTTP_PORT" "$LAST_PORT"
    prompt_single_port "NGINX_HTTP_ALT_PORT" "Nginx HTTP-ALT(nginx)" "80"; set_env_var "NGINX_HTTP_ALT_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "MinIO(minio)"; set_env_var "ENABLE_MINIO" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "MINIO_API_PORT" "MinIO API(minio)" "9000"; set_env_var "MINIO_API_PORT" "$LAST_PORT"
    prompt_single_port "MINIO_CONSOLE_PORT" "MinIO Console(minio)" "9001"; set_env_var "MINIO_CONSOLE_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "EMQX(emqx)"; set_env_var "ENABLE_EMQX" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "EMQX_MQTT_PORT" "EMQX MQTT(emqx)" "1883"; set_env_var "EMQX_MQTT_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_HTTP_API_PORT" "EMQX HTTP API(emqx)" "8081"; set_env_var "EMQX_HTTP_API_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_WS_PORT" "EMQX WS(emqx)" "8083"; set_env_var "EMQX_WS_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_SSL_MQTT_PORT" "EMQX SSL MQTT(emqx)" "8883"; set_env_var "EMQX_SSL_MQTT_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_WSS_PORT" "EMQX WSS(emqx)" "8084"; set_env_var "EMQX_WSS_PORT" "$LAST_PORT"
    prompt_single_port "EMQX_DASHBOARD_PORT" "EMQX Dashboard(emqx)" "18083"; set_env_var "EMQX_DASHBOARD_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "MongoDB(mongo)"; set_env_var "ENABLE_MONGO" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "MONGO_PORT" "MongoDB(mongo)" "27017"; set_env_var "MONGO_PORT" "$LAST_PORT"
  fi

  prompt_enable_service "etcd"; set_env_var "ENABLE_ETCD" "$LAST_BOOL"; etcd_enabled="$LAST_BOOL"

  prompt_enable_service "APISIX(apisix)"; set_env_var "ENABLE_APISIX" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ] && [ "$etcd_enabled" != "true" ]; then
    echo "[install] APISIX 依赖 etcd，已自动启用 etcd"
    set_env_var "ENABLE_ETCD" "true"
    etcd_enabled="true"
  fi

  prompt_enable_service "APISIX Dashboard(apisix-dashboard)"; set_env_var "ENABLE_APISIX_DASHBOARD" "$LAST_BOOL"
  if [ "$LAST_BOOL" = "true" ]; then
    prompt_single_port "APISIX_DASHBOARD_PORT" "APISIX Dashboard" "9000"; set_env_var "APISIX_DASHBOARD_PORT" "$LAST_PORT"
  fi
}

prompt_enable_service() {
  local service_name="$1"
  local ans=""
  while :; do
    read -r -p "是否创建 ${service_name}? [Y/n]: " ans
    ans="${ans:-Y}"
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
  while :; do
    if [ -z "$PROJECT_NAME" ]; then
      read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
    fi
    if [ -z "$PROJECT_NAME" ]; then
      echo "[install] 项目名称不能为空，请重新输入" >&2
      continue
    fi
    if project_exists "$PROJECT_NAME"; then
      echo "[install] 项目名称已存在: $PROJECT_NAME，请重新输入新的项目名称" >&2
      PROJECT_NAME=""
      continue
    fi
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

  if [[ "$os_version" == *"CentOS"* || "$os_version" == *"Rocky"* ]]; then
    echo "当前为 CentOS 系统: $os_version"
  elif [[ "$os_version" == *"Ubuntu"* ]]; then
    echo "当前为 Ubuntu 系统: $os_version"
  else
    echo "不支持的操作系统: $os_version"
    echo "脚本退出"
    exit 1
  fi

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

  if [ -f "$SCRIPT_DIR/dockerx/docker-x" ]; then
    mkdir -p "$HOME/.docker/cli-plugins"
    cp "$SCRIPT_DIR/dockerx/docker-x" "$HOME/.docker/cli-plugins/docker-x"
    chmod +x "$HOME/.docker/cli-plugins/docker-x"
    echo "[install] 已安装 docker-x 到 $HOME/.docker/cli-plugins/docker-x"
    echo "[install] 可使用: docker x ps / docker x logs"
  else
    echo "[install] 未找到 ./dockerx/docker-x，跳过安装 docker-x"
  fi

  if [ -f "$SCRIPT_DIR/dockerx/docker-ps" ]; then
    sudo cp "$SCRIPT_DIR/dockerx/docker-ps" /usr/local/bin/docker-ps
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
  sudo cp "$SCRIPT_DIR/docker_daemon.json" /etc/docker/daemon.json

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

run_restore() {
  if [ ! -x "$SCRIPT_DIR/scripts/restore.sh" ]; then
    echo "[install] 未找到 restore.sh: $SCRIPT_DIR/scripts/restore.sh" >&2
    exit 1
  fi

  if [ -n "$PROJECT_NAME" ] && [ -n "$RESTORE_SOURCE" ]; then
    "$SCRIPT_DIR/scripts/restore.sh" --bundle "$BUNDLE_DIR" --password "$COMMON_PASSWORD" --skip-images --project "$PROJECT_NAME" --source "$RESTORE_SOURCE"
  elif [ -n "$PROJECT_NAME" ]; then
    "$SCRIPT_DIR/scripts/restore.sh" --bundle "$BUNDLE_DIR" --password "$COMMON_PASSWORD" --skip-images --project "$PROJECT_NAME"
  elif [ -n "$RESTORE_SOURCE" ]; then
    "$SCRIPT_DIR/scripts/restore.sh" --bundle "$BUNDLE_DIR" --password "$COMMON_PASSWORD" --skip-images --source "$RESTORE_SOURCE"
  else
    "$SCRIPT_DIR/scripts/restore.sh" --bundle "$BUNDLE_DIR" --password "$COMMON_PASSWORD" --skip-images
  fi
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
  1) raw
  2) logical
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

main() {
  parse_args "$@"
  choose_mode_if_missing

  case "$MODE" in
    base)
      choose_project_name
      prompt_common_password
      write_common_password_env
      prompt_ports_for_base
      install_docker_and_runtime
      echo "[install] 安装完成，准备启动 infra-base..."
      sh "$SCRIPT_DIR/start.sh" "$PROJECT_NAME"
      ;;

    full)
      choose_project_name
      if [ ! -d "$BUNDLE_DIR" ]; then
        echo "[install] bundle 目录不存在: $BUNDLE_DIR" >&2
        exit 1
      fi
      prompt_common_password
      write_common_password_env
      prompt_ports_for_base
      install_docker_and_runtime
      load_images_from_bundle

      if [ -z "$RESTORE_SOURCE" ]; then
        detect_restore_source_mode
      fi
      normalize_restore_source

      if [ "$RESTORE_SOURCE" = "raw" ]; then
        run_restore
        echo "[install] 恢复完成，准备启动 infra-base..."
        sh "$SCRIPT_DIR/start.sh" "$PROJECT_NAME"
      elif [ "$RESTORE_SOURCE" = "logical" ]; then
        echo "[install] 先启动 infra-base，再执行 logical 恢复..."
        sh "$SCRIPT_DIR/start.sh" "$PROJECT_NAME"
        run_restore
      else
        echo "[install] 无效的恢复源: $RESTORE_SOURCE" >&2
        exit 1
      fi
      ;;

    restore)
      if [ ! -d "$BUNDLE_DIR" ]; then
        echo "[install] bundle 目录不存在: $BUNDLE_DIR" >&2
        exit 1
      fi
      prompt_common_password
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
