#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
  read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
fi
if [ -z "$PROJECT_NAME" ]; then
  echo "[start] 项目名称不能为空" >&2
  exit 1
fi

export COMPOSE_PROJECT_NAME="$PROJECT_NAME"

echo "[start] 生成服务端口清单..."
"$SCRIPT_DIR/generate_services.sh"

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

$SUDO docker network inspect infra-base_net >/dev/null 2>&1 || \
  $SUDO docker network create infra-base_net

echo "[start] 启动 infra-base (project: $COMPOSE_PROJECT_NAME)..."
cd "$SCRIPT_DIR"
$COMPOSE_BIN up -d

echo "[start] 启动 apisix (project: $COMPOSE_PROJECT_NAME)..."
cd "$SCRIPT_DIR/apisix"
$COMPOSE_BIN up -d
