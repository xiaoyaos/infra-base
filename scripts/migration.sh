#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ROOT="$BASE_DIR/migration_bundle"

DEFAULT_PG_USER="postgres"
DEFAULT_PG_PASSWORD=""
DEFAULT_MONGO_USER="admin"
DEFAULT_MONGO_PASSWORD=""
DEFAULT_MINIO_USER="minio"
DEFAULT_MINIO_PASSWORD=""

INCLUDE_PG=true
INCLUDE_MONGO=true
INCLUDE_MINIO=true
COMMON_PASSWORD="${COMMON_PASSWORD:-}"

log() {
  echo "[migration] $*"
}

err() {
  echo "[migration] $*" >&2
}

usage() {
  cat <<'USAGE'
用法:
  sh scripts/migration.sh [--password <pwd>]

说明:
  --password 统一密码(不传则交互输入，必填)
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令: $1"
    exit 1
  }
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
  local input=""
  while :; do
    read -r -p "请输入项目名称(用于定位运行容器): " input
    if [ -z "$input" ]; then
      err "项目名称不能为空，请重新输入"
      continue
    fi
    if project_exists "$input"; then
      echo "$input"
      return 0
    fi
    err "未找到项目 $input 对应的容器，请重新输入"
  done
}

project_exists() {
  local project="$1"
  local count
  count="$(docker ps -a --filter "label=com.docker.compose.project=$project" -q | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ]
}

list_projects_one_line() {
  local projects
  projects="$(
    docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null \
      | sed '/^$/d' \
      | sort -u \
      | paste -sd ' | ' -
  )"
  if [ -z "$projects" ]; then
    echo "[migration] 当前未检测到任何 compose project"
  else
    echo "[migration] 当前可用 project: $projects"
  fi
}

next_version() {
  mkdir -p "$BUNDLE_ROOT"
  local versions
  versions="$(find "$BUNDLE_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  if [ -z "$versions" ]; then
    echo "1.0.0"
    return
  fi

  echo "$versions" | awk -F. '
  {
    major=$1+0; minor=$2+0; patch=$3+0;
    if (!max_set || major>max_major || (major==max_major && minor>max_minor) || (major==max_major && minor==max_minor && patch>max_patch)) {
      max_major=major; max_minor=minor; max_patch=patch; max_set=1;
    }
  }
  END {
    if (!max_set) {
      print "1.0.0";
    } else {
      printf "%d.%d.%d\n", max_major, max_minor, max_patch+1;
    }
  }'
}

container_by_service() {
  local project="$1"
  local service="$2"
  docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=$service" \
    --format '{{.ID}}' | head -n1
}

copy_base_project() {
  local dst="$1"
  local tmp_excludes="$dst/.exclude.tmp"

  cat > "$tmp_excludes" <<'EOL'
.git/
migration_bundle/
production_data/
node_modules/
*.log
.DS_Store
EOL

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude-from="$tmp_excludes" "$BASE_DIR/" "$dst/"
  else
    tar -C "$BASE_DIR" -cf - . \
      --exclude='.git' \
      --exclude='migration_bundle' \
      --exclude='production_data' \
      --exclude='node_modules' \
      --exclude='*.log' \
      --exclude='.DS_Store' | tar -C "$dst" -xf -
  fi
  rm -f "$tmp_excludes"
}

prepare_bundle_dirs() {
  local bundle_dir="$1"
  mkdir -p "$bundle_dir/images" "$bundle_dir/data/logical"
}

backup_raw_data() {
  local bundle_dir="$1"
  local src="$BASE_DIR/production_data"
  local dst_root="$bundle_dir/production_data"

  if [ ! -d "$src" ]; then
    err "未找到 $src，跳过 raw 备份"
    return 1
  fi

  log "按选择复制 raw 数据目录到 bundle/production_data ..."
  mkdir -p "$dst_root"
  if [ "$INCLUDE_PG" = true ] && [ -d "$src/tsdb" ]; then
    mkdir -p "$dst_root/tsdb"
    rsync_or_copy "$src/tsdb" "$dst_root/tsdb"
  fi
  if [ "$INCLUDE_MONGO" = true ] && [ -d "$src/mongo" ]; then
    mkdir -p "$dst_root/mongo"
    rsync_or_copy "$src/mongo" "$dst_root/mongo"
  fi
  if [ "$INCLUDE_MINIO" = true ] && [ -d "$src/minio" ]; then
    mkdir -p "$dst_root/minio"
    rsync_or_copy "$src/minio" "$dst_root/minio"
  fi
  return 0
}

rsync_or_copy() {
  local src="$1"
  local dst="$2"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$src/" "$dst/"
  else
    tar -C "$src" -cf - . | tar -C "$dst" -xf -
  fi
}

backup_pg_logical() {
  local cid="$1"
  local out_dir="$2"
  local log_file
  log_file="$(mktemp)"

  echo "[postgres] 备份中..."
  {
    mkdir -p "$out_dir"

    docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
      pg_dumpall --globals-only -U "$DEFAULT_PG_USER" > "$out_dir/globals.sql"

    local db_list
    db_list="$(docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
      psql -t -A -U "$DEFAULT_PG_USER" -d postgres \
      -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true ORDER BY datname;")"

    : > "$out_dir/db_list.txt"
    : > "$out_dir/db_meta.tsv"
    while IFS= read -r db; do
      [ -z "$db" ] && continue
      echo "$db" >> "$out_dir/db_list.txt"
      local has_tsdb
      has_tsdb="$(docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
        psql -t -A -U "$DEFAULT_PG_USER" -d "$db" \
        -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb';" | tr -d '[:space:]')"
      if [ "$has_tsdb" = "1" ]; then
        echo "${db}\ttrue" >> "$out_dir/db_meta.tsv"
      else
        echo "${db}\tfalse" >> "$out_dir/db_meta.tsv"
      fi
      docker exec -e PGPASSWORD="$DEFAULT_PG_PASSWORD" "$cid" \
        pg_dump -Fc -U "$DEFAULT_PG_USER" -d "$db" > "$out_dir/${db}.dump"
    done <<< "$db_list"
  } >"$log_file" 2>&1 || {
    echo "[postgres] 备份失败，详情如下:" >&2
    cat "$log_file" >&2
    rm -f "$log_file"
    return 1
  }

  rm -f "$log_file"
  echo "[postgres] 备份完成"
}

backup_mongo_logical() {
  local cid="$1"
  local out="$2"
  local log_file
  log_file="$(mktemp)"

  echo "[mongo] 备份中..."
  {
    docker exec "$cid" mongodump \
      --authenticationDatabase admin \
      -u "$DEFAULT_MONGO_USER" \
      -p "$DEFAULT_MONGO_PASSWORD" \
      --archive --gzip > "$out"
  } >"$log_file" 2>&1 || {
    echo "[mongo] 备份失败，详情如下:" >&2
    cat "$log_file" >&2
    rm -f "$log_file"
    return 1
  }

  rm -f "$log_file"
  echo "[mongo] 备份完成"
}

backup_minio_logical() {
  local minio_cid="$1"
  local out_dir="$2"
  local tmp_dir="/tmp/minio-logical-backup"
  local log_file
  log_file="$(mktemp)"

  if ! docker exec "$minio_cid" sh -c "command -v mc >/dev/null 2>&1"; then
    rm -f "$log_file"
    err "minio 容器内未找到 mc，无法执行 MinIO 逻辑备份"
    return 1
  fi

  echo "[minio] 备份中..."
  {
    mkdir -p "$out_dir"

    docker exec "$minio_cid" sh -c "rm -rf '$tmp_dir' && mkdir -p '$tmp_dir' && mc alias set src http://127.0.0.1:9000 $DEFAULT_MINIO_USER $DEFAULT_MINIO_PASSWORD >/dev/null && mc mirror --overwrite src '$tmp_dir'"
    docker cp "$minio_cid:$tmp_dir/." "$out_dir/"
    docker exec "$minio_cid" sh -c "rm -rf '$tmp_dir'" >/dev/null 2>&1 || true
  } >"$log_file" 2>&1 || {
    echo "[minio] 备份失败，详情如下:" >&2
    cat "$log_file" >&2
    rm -f "$log_file"
    return 1
  }

  rm -f "$log_file"
  echo "[minio] 备份完成"
}

backup_logical_data() {
  local bundle_dir="$1"
  local project="$2"

  local pg_cid mongo_cid minio_cid
  pg_cid="$(container_by_service "$project" "tsdb")"
  mongo_cid="$(container_by_service "$project" "mongo")"
  minio_cid="$(container_by_service "$project" "minio")"

  if [ -z "$pg_cid" ] || [ -z "$mongo_cid" ]; then
    err "未找到 tsdb/mongo 运行容器，请确认项目名称和容器状态"
    return 1
  fi

  mkdir -p "$bundle_dir/data/logical"

  if [ "$INCLUDE_PG" = true ]; then
    backup_pg_logical "$pg_cid" "$bundle_dir/data/logical/pg"
  fi
  if [ "$INCLUDE_MONGO" = true ]; then
    backup_mongo_logical "$mongo_cid" "$bundle_dir/data/logical/mongo.archive.gz"
  fi

  if [ "$INCLUDE_MINIO" = true ]; then
    if [ -z "$minio_cid" ]; then
      err "未找到 minio 运行容器，请确认项目名称和容器状态"
      return 1
    fi
    backup_minio_logical "$minio_cid" "$bundle_dir/data/logical/minio"
  fi
}

collect_images() {
  local compose_bin="$1"
  local project="$2"
  local tmp_list="$3"

  : > "$tmp_list"

  $compose_bin -f "$BASE_DIR/docker-compose.yml" config 2>/dev/null \
    | awk '/^[[:space:]]*image:[[:space:]]*/{print $2}' >> "$tmp_list" || true
  $compose_bin -f "$BASE_DIR/apisix/docker-compose.yml" config 2>/dev/null \
    | awk '/^[[:space:]]*image:[[:space:]]*/{print $2}' >> "$tmp_list" || true

  if [ -n "$project" ]; then
    docker ps --filter "label=com.docker.compose.project=$project" --format '{{.Image}}' >> "$tmp_list" || true
  fi

  sed -i.bak '/^$/d' "$tmp_list" && rm -f "$tmp_list.bak"
  sort -u "$tmp_list" -o "$tmp_list"
}

build_existing_image_list() {
  local src_list="$1"
  local dst_list="$2"
  local missing_list="$3"
  : > "$dst_list"
  : > "$missing_list"

  while read -r img; do
    [ -z "$img" ] && continue
    if docker image inspect "$img" >/dev/null 2>&1; then
      echo "$img" >> "$dst_list"
    else
      echo "$img" >> "$missing_list"
    fi
  done < "$src_list"
}

export_images() {
  local bundle_dir="$1"
  local project="$2"
  local compose_bin="$3"
  local list_file="$bundle_dir/images/images.txt"
  local existing_list="$bundle_dir/images/images.existing.txt"
  local missing_list="$bundle_dir/images/images.missing.txt"

  collect_images "$compose_bin" "$project" "$list_file"
  build_existing_image_list "$list_file" "$existing_list" "$missing_list"

  if [ ! -s "$existing_list" ]; then
    err "未收集到镜像，跳过导出"
    return 1
  fi

  if [ -s "$missing_list" ]; then
    log "以下镜像本机不存在，已跳过导出(不会中断):"
    sed 's/^/[migration]   - /' "$missing_list"
  fi

  log "导出离线镜像到 images/all-images.tar ..."
  # shellcheck disable=SC2046
  docker save -o "$bundle_dir/images/all-images.tar" $(cat "$existing_list")
}

write_manifest() {
  local bundle_dir="$1"
  local version="$2"
  local desc="$3"
  local backup_mode="$4"
  local include_images="$5"

  cat > "$bundle_dir/manifest.json" <<EOF_MANIFEST
{
  "version": "$version",
  "description": "$desc",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S %z')",
  "backup_mode": "$backup_mode",
  "include_items": {
    "pg": $INCLUDE_PG,
    "mongo": $INCLUDE_MONGO,
    "minio": $INCLUDE_MINIO
  },
  "include_images": $include_images,
  "generator": "migration.sh"
}
EOF_MANIFEST
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

write_checksums() {
  local bundle_dir="$1"
  log "生成 checksums.sha256 ..."
  (
    cd "$bundle_dir"
    if command -v sha256sum >/dev/null 2>&1; then
      find . -type f ! -name 'checksums.sha256' -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
    else
      find . -type f ! -name 'checksums.sha256' -print0 | sort -z | xargs -0 shasum -a 256 > checksums.sha256
    fi
  )
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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

  need_cmd docker
  prompt_common_password
  local compose_bin
  compose_bin="$(compose_cmd)" || {
    err "未检测到 docker compose"
    exit 1
  }

  # 项目名必须先输入并通过校验，避免后续打包到一半才失败。
  local PROJECT_NAME
  list_projects_one_line
  PROJECT_NAME="$(choose_project_name)"

  mkdir -p "$BUNDLE_ROOT"

  local auto_version
  auto_version="$(next_version)"

  local VERSION=""
  while :; do
    read -r -p "请输入迁移包版本(默认 $auto_version): " VERSION
    VERSION="${VERSION:-$auto_version}"
    if echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      break
    fi
    err "版本号格式不正确，请输入 x.y.z（例如 1.0.1）"
  done

  local DESCRIPTION=""
  while :; do
    read -r -p "请输入本次迁移描述(必填): " DESCRIPTION
    if [ -n "$DESCRIPTION" ]; then
      break
    fi
    err "描述不能为空，请重新输入"
  done

  cat <<'EOF_MENU'
请选择数据备份模式:
  1) raw (production_data 原始目录)
  2) logical (pg/mongo/minio 逻辑备份)
  3) both (raw + logical)
EOF_MENU
  read -r -p "请输入选项 [1/2/3] (默认 1): " MODE_CHOICE
  MODE_CHOICE="${MODE_CHOICE:-1}"

  local BACKUP_MODE
  case "$MODE_CHOICE" in
    1) BACKUP_MODE="raw" ;;
    2) BACKUP_MODE="logical" ;;
    3) BACKUP_MODE="both" ;;
    *) err "无效选项"; exit 1 ;;
  esac

  if [ "$BACKUP_MODE" = "raw" ] || [ "$BACKUP_MODE" = "both" ]; then
    log "提示: 选择 raw 数据迁移时，目标环境恢复必须使用源环境统一密码，不能指定新密码"
  fi

  read -r -p "是否导出离线镜像? [y/N]: " IMAGE_CHOICE
  IMAGE_CHOICE="${IMAGE_CHOICE:-N}"

  echo "请选择需要备份的数据项(默认全选):"
  INCLUDE_PG="$(ask_yes_no_default_y "  - PostgreSQL(tsdb)")"
  INCLUDE_MONGO="$(ask_yes_no_default_y "  - MongoDB(mongo)")"
  INCLUDE_MINIO="$(ask_yes_no_default_y "  - MinIO(minio)")"

  local BUNDLE_DIR="$BUNDLE_ROOT/$VERSION"
  if [ -e "$BUNDLE_DIR" ]; then
    err "版本目录已存在: $BUNDLE_DIR"
    exit 1
  fi

  log "复制 infra-base 基础文件到迁移目录..."
  mkdir -p "$BUNDLE_DIR"
  copy_base_project "$BUNDLE_DIR"
  prepare_bundle_dirs "$BUNDLE_DIR"

  local has_raw=false
  local has_logical=false

  if [ "$BACKUP_MODE" = "raw" ] || [ "$BACKUP_MODE" = "both" ]; then
    backup_raw_data "$BUNDLE_DIR" && has_raw=true || true
  fi

  if [ "$BACKUP_MODE" = "logical" ] || [ "$BACKUP_MODE" = "both" ]; then
    log "开始逻辑备份前，请确认业务写入已暂停，以保证一致性"
    backup_logical_data "$BUNDLE_DIR" "$PROJECT_NAME"
    has_logical=true
  fi

  local include_images=false
  if [[ "$IMAGE_CHOICE" =~ ^[Yy]$ ]]; then
    export_images "$BUNDLE_DIR" "$PROJECT_NAME" "$compose_bin"
    include_images=true
  fi

  write_manifest "$BUNDLE_DIR" "$VERSION" "$DESCRIPTION" "$BACKUP_MODE" "$include_images"
  write_checksums "$BUNDLE_DIR"

  log "迁移包生成完成: $BUNDLE_DIR"
  log "数据备份状态: raw=$has_raw logical=$has_logical images=$include_images"
}

main "$@"
