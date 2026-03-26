#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"

usage() {
  cat <<'USAGE'
infra-base 统一入口

用法
  sh infractl.sh
  sh infractl.sh --help

支持功能
  1) 基础包安装（base）
  2) 生成迁移包（migration backup）
  3) 迁移包安装（full）
  4) 数据恢复（restore）
  5) 健康检查（check）
  6) 启动基础服务（start）
  7) 卸载基础服务（uninstall，不含业务服务）
  8) 部署业务服务（deploy services，独立管理）
  9) 初始化样例数据

说明
  - 本脚本是根目录唯一外部入口
  - 执行后按菜单数字交互即可
USAGE
}

require_script() {
  local path="$1"
  [ -f "$path" ] || {
    echo "[entry] 脚本不存在: $path" >&2
    exit 1
  }
}

prompt_non_empty() {
  local prompt="$1"
  local value=""
  while :; do
    read -r -p "$prompt" value
    if [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
    echo "[entry] 输入不能为空，请重新输入" >&2
  done
}

prompt_bundle_dir() {
  local tip="$1"
  local value=""
  while :; do
    read -r -p "$tip" value
    value="${value:-$PWD}"
    if [ -d "$value" ]; then
      echo "$value"
      return 0
    fi
    echo "[entry] 目录不存在: $value，请重新输入" >&2
  done
}

run_install_mode() {
  local mode="$1"
  local bundle="${2:-}"
  if [ -n "$bundle" ]; then
    bash "$SCRIPTS_DIR/install.sh" --mode "$mode" --bundle "$bundle"
  else
    bash "$SCRIPTS_DIR/install.sh" --mode "$mode"
  fi
}

run_check() {
  local project
  project="$(prompt_non_empty "请输入项目名称(用于检查): ")"
  bash "$SCRIPTS_DIR/check.sh" --project "$project"
}

run_start() {
  local project
  project="$(prompt_non_empty "请输入项目名称(用于启动): ")"
  bash "$SCRIPTS_DIR/start.sh" "$project"
}

run_uninstall() {
  local project
  project="$(prompt_non_empty "请输入项目名称(用于卸载): ")"
  bash "$SCRIPTS_DIR/uninstall.sh" "$project"
}

run_deploy_services() {
  local project network files
  project="$(prompt_non_empty "请输入项目名称(用于 docker compose project name): ")"
  network="infra-base-$project"
  read -r -p "请输入业务 compose 文件路径(多个用空格分隔): " files
  if [ -z "$files" ]; then
    echo "[entry] 至少需要一个 compose 文件路径" >&2
    exit 1
  fi

  local f
  set -- -p "$project" -n "$network"
  for f in $files; do
    set -- "$@" -f "$f"
  done
  bash "$SCRIPTS_DIR/deploy_services.sh" "$@"
}

menu() {
  cat <<'EOF_MENU'
请选择操作（输入数字）:
  1) 基础包安装（base）
  2) 生成迁移包（migration backup）
  3) 迁移包安装（full）
  4) 数据恢复（restore）
  5) 健康检查（check）
  6) 启动基础服务（start）
  7) 卸载基础服务（uninstall，不含业务服务）
  8) 部署业务服务（deploy services，独立管理）
  9) 初始化样例数据（init sample data）
  0) 退出
EOF_MENU

  local choice=""
  while :; do
    read -r -p "请输入选项 [0-9] (必填): " choice
    case "$choice" in
      1)
        run_install_mode "base"
        return 0
        ;;
      2)
        bash "$SCRIPTS_DIR/migration.sh"
        return 0
        ;;
      3)
        local bundle_full
        bundle_full="$(prompt_bundle_dir "请输入迁移包目录(默认当前目录): ")"
        run_install_mode "full" "$bundle_full"
        return 0
        ;;
      4)
        local bundle_restore
        bundle_restore="$(prompt_bundle_dir "请输入恢复包目录(默认当前目录): ")"
        run_install_mode "restore" "$bundle_restore"
        return 0
        ;;
      5)
        run_check
        return 0
        ;;
      6)
        run_start
        return 0
        ;;
      7)
        run_uninstall
        return 0
        ;;
      8)
        run_deploy_services
        return 0
        ;;
      9)
        local project
        project="$(prompt_non_empty "请输入项目名称(用于初始化样例数据): ")"
        bash "$SCRIPTS_DIR/init_sample_data.sh" --project "$project"
        return 0
        ;;
      0)
        echo "已退出"
        return 0
        ;;
      *)
        echo "[entry] 无效选项，请输入 0-9" >&2
        ;;
    esac
  done
}

main() {
  require_script "$SCRIPTS_DIR/install.sh"
  require_script "$SCRIPTS_DIR/start.sh"
  require_script "$SCRIPTS_DIR/uninstall.sh"
  require_script "$SCRIPTS_DIR/deploy_services.sh"
  require_script "$SCRIPTS_DIR/migration.sh"
  require_script "$SCRIPTS_DIR/restore.sh"
  require_script "$SCRIPTS_DIR/check.sh"
  require_script "$SCRIPTS_DIR/init_sample_data.sh"

  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
  fi

  if [ $# -gt 0 ]; then
    bash "$SCRIPTS_DIR/install.sh" "$@"
    exit $?
  fi

  menu
}

main "$@"
