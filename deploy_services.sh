#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
  cat <<'USAGE'
用法:
  ./deploy_services.sh -p <项目名> -n <网络名> -f <compose文件> [-f <compose文件> ...]

示例:
  ./deploy_services.sh -p demo -n infra-base_net -f /path/to/order/docker-compose.yml -f /path/to/device/docker-compose.yml

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
  echo "[deploy] 启动服务: $f"
  $COMPOSE_BIN -f "$f" up -d
done

echo "[deploy] 完成"
