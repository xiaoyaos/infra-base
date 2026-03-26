#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SUDO=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[uninstall] 未找到 docker" >&2
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
  echo "[uninstall] 未检测到 docker compose" >&2
  exit 1
}

echo "[uninstall] 当前已存在的 compose 项目:"
docker compose ls --format json 2>/dev/null \
  | awk -F'"Name":"' '{for(i=2;i<=NF;i++){split($i,a,"\""); print a[1]}}' \
  | sort -u || true
echo "[uninstall] 提示: 本脚本仅卸载 infra-base/apisix；通过 deploy_services.sh 部署的业务服务需在其 compose 目录自行 down"

PROJECT_NAME="${1:-}"
while :; do
  if [ -z "$PROJECT_NAME" ]; then
    read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
  fi
  if [ -z "$PROJECT_NAME" ]; then
    echo "[uninstall] 项目名称不能为空" >&2
    continue
  fi
  if [ "$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" -q | wc -l | tr -d ' ')" = "0" ]; then
    echo "[uninstall] 未找到项目 $PROJECT_NAME，请重新输入" >&2
    PROJECT_NAME=""
    continue
  fi
  break
done

export COMPOSE_PROJECT_NAME="$PROJECT_NAME"
export NETWORK_NAME="${NETWORK_NAME:-infra-base-${COMPOSE_PROJECT_NAME}}"

echo "[uninstall] 停止并删除 apisix (project: $COMPOSE_PROJECT_NAME)..."
$COMPOSE_BIN -f "$BASE_DIR/apisix/docker-compose.yml" down


echo "[uninstall] 停止并删除 infra-base (project: $COMPOSE_PROJECT_NAME)..."
$COMPOSE_BIN -f "$BASE_DIR/docker-compose.yml" down

echo "[uninstall] 删除网络: $NETWORK_NAME"
if $SUDO docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  if ! $SUDO docker network rm "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "[uninstall] 未删除网络 $NETWORK_NAME，可能仍有业务服务占用；请先清理业务服务后重试" >&2
  fi
fi
