#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_PG_USER="postgres"
DEFAULT_PG_PASSWORD=""
DEFAULT_MONGO_USER="admin"
DEFAULT_MONGO_PASSWORD=""
DEFAULT_MINIO_USER="minio"
DEFAULT_MINIO_PASSWORD=""

BUNDLE_DIR="$BASE_DIR"
PROJECT_NAME=""
SOURCE_MODE=""
AUTO_YES="false"
INCLUDE_PG=true
INCLUDE_MONGO=true
INCLUDE_MINIO=true
COMMON_PASSWORD="${COMMON_PASSWORD:-}"
STOPPED_IDS=""
IMPORT_IMAGES="true"

log() {
  echo "[restore] $*"
}

err() {
  echo "[restore] $*" >&2
}

usage() {
  cat <<'USAGE'
用法:
  sh scripts/restore.sh [--bundle <path>] [--project <name>] [--source raw|logical] [--password <pwd>] [--yes] [--skip-images]

说明:
  --bundle   迁移包目录，默认当前脚本目录
  --project  compose 项目名(逻辑恢复时必填)
  --source   指定恢复源(raw 或 logical)，不指定则交互式选择
  --password 统一密码(不传则交互输入，必填)
  --yes      跳过覆盖确认(仍会创建恢复前备份)
  --skip-images 跳过离线镜像导入
USAGE
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

container_by_service() {
  local project="$1"
  local service="$2"
  docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=$service" \
    --format '{{.ID}}' | head -n1
}

running_container_by_service() {
  local project="$1"
  local service="$2"
  docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=$service" \
    --format '{{.ID}}' | head -n1
}

append_stopped_id() {
  local cid="$1"
  [ -z "$cid" ] && return 0
  if [ -z "$STOPPED_IDS" ]; then
    STOPPED_IDS="$cid"
  else
    STOPPED_IDS="$STOPPED_IDS $cid"
  fi
}

stop_data_services_for_raw_restore() {
  local project="$1"
  [ -z "$project" ] && return 0

  local cid
  for svc in tsdb mongo minio; do
    cid="$(running_container_by_service "$project" "$svc")"
    if [ -n "$cid" ]; then
      log "停止数据容器: $svc ($cid)"
      docker stop "$cid" >/dev/null
      append_stopped_id "$cid"
    fi
  done
}

start_stopped_services() {
  [ -z "$STOPPED_IDS" ] && return 0
  local cid
  for cid in $STOPPED_IDS; do
    log "启动数据容器: $cid"
    docker start "$cid" >/dev/null || true
  done
  STOPPED_IDS=""
}

ensure_dirs() {
  mkdir -p "$BASE_DIR/production_data"
  mkdir -p "$BASE_DIR/production_data/tsdb"
  mkdir -p "$BASE_DIR/production_data/mongo"
  mkdir -p "$BASE_DIR/production_data/minio"
}

backup_current_production_data() {
  if [ ! -d "$BASE_DIR/production_data" ]; then
    log "当前不存在 production_data，跳过恢复前备份"
    return 0
  fi

  local backup_dir="$BASE_DIR/migration_bundle/pre_restore_backup"
  local ts
  ts="$(date '+%Y%m%d_%H%M%S')"
  mkdir -p "$backup_dir"

  local target="$backup_dir/production_data_$ts"
  log "恢复前备份当前 production_data -> $target"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$BASE_DIR/production_data/" "$target/"
  else
    mkdir -p "$target"
    tar -C "$BASE_DIR/production_data" -cf - . | tar -C "$target" -xf -
  fi
}

import_raw_data() {
  local raw_dir=""
  if [ -d "$BUNDLE_DIR/production_data" ]; then
    raw_dir="$BUNDLE_DIR/production_data"
  elif [ -d "$BUNDLE_DIR/data/raw/production_data" ]; then
    # 兼容旧版迁移包结构
    raw_dir="$BUNDLE_DIR/data/raw/production_data"
  fi

  if [ -z "$raw_dir" ]; then
    err "未找到 raw 数据目录(期望: $BUNDLE_DIR/production_data 或 $BUNDLE_DIR/data/raw/production_data)"
    return 1
  fi

  ensure_dirs
  log "覆盖恢复 raw production_data ..."

  if [ "$INCLUDE_PG" = true ] && [ -d "$raw_dir/tsdb" ]; then
    sync_component "$raw_dir/tsdb" "$BASE_DIR/production_data/tsdb"
  fi
  if [ "$INCLUDE_MONGO" = true ] && [ -d "$raw_dir/mongo" ]; then
    sync_component "$raw_dir/mongo" "$BASE_DIR/production_data/mongo"
  fi
  if [ "$INCLUDE_MINIO" = true ] && [ -d "$raw_dir/minio" ]; then
    sync_component "$raw_dir/minio" "$BASE_DIR/production_data/minio"
  fi
}

sync_component() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src/" "$dst/"
  else
    rm -rf "$dst"
    mkdir -p "$dst"
    tar -C "$src" -cf - . | tar -C "$dst" -xf -
  fi
}

restore_pg_logical() {
  local cid="$1"
  local pg_dir="$BUNDLE_DIR/data/logical/pg"
  local old_dump_file="$BUNDLE_DIR/data/logical/pg_dumpall.sql"
  local meta_file="$pg_dir/db_meta.tsv"

  if [ -d "$pg_dir" ] && [ -f "$pg_dir/globals.sql" ] && [ -f "$pg_dir/db_list.txt" ]; then
    log "恢复 PostgreSQL 逻辑备份(pg_restore)..."
    docker cp "$pg_dir/globals.sql" "$cid:/tmp/pg_globals.sql"
    docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
      psql -U "$DEFAULT_PG_USER" -d postgres -f /tmp/pg_globals.sql
    docker exec "$cid" rm -f /tmp/pg_globals.sql >/dev/null 2>&1 || true

    while IFS= read -r db; do
      [ -z "$db" ] && continue
      local dump_file="$pg_dir/${db}.dump"
      [ -f "$dump_file" ] || { err "缺少 PG 数据库备份文件: $dump_file"; return 1; }
      local has_tsdb="false"
      if [ -f "$meta_file" ]; then
        has_tsdb="$(awk -F'\t' -v d="$db" '$1==d{print $2; exit}' "$meta_file")"
        [ -n "$has_tsdb" ] || has_tsdb="false"
      fi

      local db_exists
      db_exists="$(docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
        psql -t -A -U "$DEFAULT_PG_USER" -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${db}';" | tr -d '[:space:]')"
      if [ "$db_exists" != "1" ]; then
        docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
          psql -U "$DEFAULT_PG_USER" -d postgres -c "CREATE DATABASE \"${db}\";"
      fi

      docker cp "$dump_file" "$cid:/tmp/${db}.dump"
      if [ "$has_tsdb" != "true" ]; then
        if docker exec "$cid" sh -c "pg_restore -l /tmp/${db}.dump | grep -q 'EXTENSION - timescaledb'" >/dev/null 2>&1; then
          has_tsdb="true"
        fi
      fi
      if [ "$has_tsdb" = "true" ]; then
        log "检测到数据库 $db 启用 timescaledb，启用兼容恢复流程..."
        docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
          psql -X -U "$DEFAULT_PG_USER" -d "$db" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
        docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
          psql -X -U "$DEFAULT_PG_USER" -d "$db" -c "SELECT timescaledb_pre_restore();"

        docker exec "$cid" sh -c "pg_restore -l /tmp/${db}.dump > /tmp/${db}.list"
        docker exec "$cid" sh -c "grep -Ev 'EXTENSION - timescaledb|COMMENT - EXTENSION timescaledb' /tmp/${db}.list > /tmp/${db}.filtered.list"
        docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
          pg_restore -U "$DEFAULT_PG_USER" -d "$db" --clean --if-exists --no-owner --no-privileges -L "/tmp/${db}.filtered.list" "/tmp/${db}.dump"
        docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
          psql -X -U "$DEFAULT_PG_USER" -d "$db" -c "SELECT timescaledb_post_restore();"
        docker exec "$cid" rm -f "/tmp/${db}.list" "/tmp/${db}.filtered.list" >/dev/null 2>&1 || true
      else
        docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
          pg_restore -U "$DEFAULT_PG_USER" -d "$db" --clean --if-exists --no-owner --no-privileges "/tmp/${db}.dump"
      fi
      docker exec "$cid" rm -f "/tmp/${db}.dump" >/dev/null 2>&1 || true
    done < "$pg_dir/db_list.txt"
    return 0
  fi

  # 兼容旧版迁移包（pg_dumpall.sql）
  [ -f "$old_dump_file" ] || { err "缺少 PG dump: $old_dump_file"; return 1; }
  log "恢复 PostgreSQL 逻辑备份(兼容模式 pg_dumpall.sql)..."
  docker cp "$old_dump_file" "$cid:/tmp/pg_dumpall.sql"
  docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
    psql -U "$DEFAULT_PG_USER" -f /tmp/pg_dumpall.sql
  docker exec "$cid" rm -f /tmp/pg_dumpall.sql >/dev/null 2>&1 || true
}

restore_mongo_logical() {
  local cid="$1"
  local dump_file="$BUNDLE_DIR/data/logical/mongo.archive.gz"
  [ -f "$dump_file" ] || { err "缺少 Mongo dump: $dump_file"; return 1; }

  log "恢复 MongoDB 逻辑备份..."
  docker cp "$dump_file" "$cid:/tmp/mongo.archive.gz"
  docker exec "$cid" mongorestore \
    --authenticationDatabase admin \
    -u "$DEFAULT_MONGO_USER" \
    -p "$DEFAULT_MONGO_PASSWORD" \
    --drop --gzip --archive=/tmp/mongo.archive.gz
  docker exec "$cid" rm -f /tmp/mongo.archive.gz >/dev/null 2>&1 || true
}

restore_minio_logical() {
  local minio_cid="$1"
  local minio_dir="$BUNDLE_DIR/data/logical/minio"
  local tmp_dir="/tmp/minio-logical-restore"
  [ -d "$minio_dir" ] || { err "缺少 MinIO 逻辑备份目录: $minio_dir"; return 1; }

  if ! docker exec "$minio_cid" sh -c "command -v mc >/dev/null 2>&1"; then
    err "minio 容器内未找到 mc，无法执行 MinIO 逻辑恢复"
    return 1
  fi

  log "恢复 MinIO 对象(容器内 mc mirror)..."
  docker exec "$minio_cid" sh -c "rm -rf '$tmp_dir' && mkdir -p '$tmp_dir'"
  docker cp "$minio_dir/." "$minio_cid:$tmp_dir/"
  docker exec "$minio_cid" sh -c "mc alias set dst http://127.0.0.1:9000 $DEFAULT_MINIO_USER $DEFAULT_MINIO_PASSWORD >/dev/null && mc mirror --overwrite '$tmp_dir' dst"
  docker exec "$minio_cid" sh -c "rm -rf '$tmp_dir'" >/dev/null 2>&1 || true
}

import_logical_data() {
  local project="$1"

  local pg_cid mongo_cid minio_cid
  pg_cid="$(container_by_service "$project" "tsdb")"
  mongo_cid="$(container_by_service "$project" "mongo")"
  minio_cid="$(container_by_service "$project" "minio")"

  [ -n "$pg_cid" ] || { err "未找到 tsdb 容器"; return 1; }
  [ -n "$mongo_cid" ] || { err "未找到 mongo 容器"; return 1; }

  ensure_dirs
  if [ "$INCLUDE_PG" = true ]; then
    restore_pg_logical "$pg_cid"
  fi
  if [ "$INCLUDE_MONGO" = true ]; then
    restore_mongo_logical "$mongo_cid"
  fi

  if [ "$INCLUDE_MINIO" = true ]; then
    [ -n "$minio_cid" ] || { err "未找到 minio 容器"; return 1; }
    restore_minio_logical "$minio_cid"
  fi
}

import_images_if_exists() {
  local image_tar="$BUNDLE_DIR/images/all-images.tar"
  if [ ! -f "$image_tar" ]; then
    log "未发现离线镜像包，跳过镜像导入"
    return 0
  fi

  log "导入离线镜像: $image_tar"
  docker load -i "$image_tar"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle)
        BUNDLE_DIR="${2:-}"; shift 2 ;;
      --project)
        PROJECT_NAME="${2:-}"; shift 2 ;;
      --source)
        SOURCE_MODE="${2:-}"; shift 2 ;;
      --yes)
        AUTO_YES="true"; shift ;;
      --skip-images)
        IMPORT_IMAGES="false"; shift ;;
      --password)
        COMMON_PASSWORD="${2:-}"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        err "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done
}

load_common_password() {
  if [ -n "$COMMON_PASSWORD" ]; then
    DEFAULT_PG_PASSWORD="$COMMON_PASSWORD"
    DEFAULT_MONGO_PASSWORD="$COMMON_PASSWORD"
    DEFAULT_MINIO_PASSWORD="$COMMON_PASSWORD"
    return 0
  fi
  return 1
}

prompt_common_password() {
  if load_common_password; then
    return 0
  fi
  local input=""
  while :; do
    read -r -s -p "请输入统一密码(用于 pg/mongodb/minio，必填): " input
    echo
    if [ -n "$input" ]; then
      DEFAULT_PG_PASSWORD="$input"
      DEFAULT_MONGO_PASSWORD="$input"
      DEFAULT_MINIO_PASSWORD="$input"
      return 0
    fi
    err "统一密码不能为空，请重新输入"
  done
}

choose_source_mode() {
  if [ -n "$SOURCE_MODE" ]; then
    echo "$SOURCE_MODE"
    return
  fi

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
    err "未检测到可恢复数据源（raw/logical 都不存在）"
    exit 1
  fi

  if [ "$has_raw" = "true" ] && [ "$has_logical" = "false" ]; then
    echo "检测到仅 raw 可用，请确认恢复来源："
    echo "  1) raw：直接覆盖恢复 production_data"
    while :; do
      read -r -p "请输入选项 [1]，默认 1(raw): " choice
      choice="${choice:-1}"
      case "$choice" in
        1) echo "raw"; return ;;
        *) err "无效选项，仅支持 1";;
      esac
    done
  fi

  if [ "$has_raw" = "false" ] && [ "$has_logical" = "true" ]; then
    echo "检测到仅 logical 可用，请确认恢复来源："
    echo "  2) logical：使用逻辑备份恢复(pg_dumpall/mongodump/mc)"
    while :; do
      read -r -p "请输入选项 [2]，默认 2(logical): " choice
      choice="${choice:-2}"
      case "$choice" in
        2) echo "logical"; return ;;
        *) err "无效选项，仅支持 2";;
      esac
    done
  fi

  cat <<'EOF_MENU'
检测到 raw(production_data) 与 logical 同时可用：
请选择恢复源(输入 1 或 2，默认 2 logical):
  1) raw：直接覆盖恢复 production_data
     适用：同版本、同架构、同部署结构迁移（速度快）
  2) logical：使用逻辑备份恢复(pg_dumpall/mongodump/mc)
     适用：跨环境或兼容性优先场景（更稳，默认推荐）
EOF_MENU
  local choice
  read -r -p "请输入选项 [1/2]，默认 2(logical): " choice
  choice="${choice:-2}"
  case "$choice" in
    1) echo "raw" ;;
    2) echo "logical" ;;
    *) err "无效选项"; exit 1 ;;
  esac
}

ask_yes_no_default_y() {
  local prompt="$1"
  local ans
  read -r -p "$prompt [Y/n]: " ans
  if [[ "$ans" =~ ^[Nn]$ ]]; then
    echo "false"
  else
    echo "true"
  fi
}

choose_components() {
  echo "请选择要恢复的数据项(默认全选):"
  INCLUDE_PG="$(ask_yes_no_default_y "  - PostgreSQL(tsdb)")"
  INCLUDE_MONGO="$(ask_yes_no_default_y "  - MongoDB(mongo)")"
  INCLUDE_MINIO="$(ask_yes_no_default_y "  - MinIO(minio)")"
}

confirm_overwrite() {
  if [ "$AUTO_YES" = "true" ]; then
    return 0
  fi

  local ans
  read -r -p "该操作会覆盖现有数据，是否继续? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

main() {
  parse_args "$@"
  prompt_common_password

  [ -d "$BUNDLE_DIR" ] || { err "bundle 目录不存在: $BUNDLE_DIR"; exit 1; }
  command -v docker >/dev/null 2>&1 || { err "未找到 docker"; exit 1; }
  compose_cmd >/dev/null 2>&1 || { err "未检测到 docker compose"; exit 1; }

  local source
  source="$(choose_source_mode)"
  choose_components

  if ! confirm_overwrite; then
    err "已取消恢复"
    exit 1
  fi

  if [ "$source" = "raw" ]; then
    if [ -z "$PROJECT_NAME" ]; then
      read -r -p "请输入项目名称(用于停启 pg/mongo/minio，回车跳过停启): " PROJECT_NAME
    fi
    stop_data_services_for_raw_restore "$PROJECT_NAME"
    # raw 恢复过程中若异常退出，尽量拉起已停止容器，避免长时间中断。
    trap 'start_stopped_services' EXIT
  fi

  backup_current_production_data
  if [ "$IMPORT_IMAGES" = "true" ]; then
    import_images_if_exists
  else
    log "按参数跳过离线镜像导入"
  fi

  case "$source" in
    raw)
      import_raw_data
      start_stopped_services
      trap - EXIT
      ;;
    logical)
      if [ -z "$PROJECT_NAME" ]; then
        read -r -p "请输入项目名称(用于定位运行中的容器): " PROJECT_NAME
      fi
      [ -n "$PROJECT_NAME" ] || { err "项目名称不能为空"; exit 1; }
      import_logical_data "$PROJECT_NAME"
      ;;
    *)
      err "未知恢复源: $source"
      exit 1
      ;;
  esac

  log "恢复完成，建议执行: sh $BASE_DIR/start.sh <project_name> 以确保服务状态正确"
}

main "$@"
