#!/usr/bin/env bash

set -euo pipefail

PROJECT_NAME=""
ACTION="init"
PG_DB="demo_db"
PG_TABLE="demo_records"
MONGO_DB="demo_db"
MONGO_COLLECTION="demo_records"
ROWS=100

PG_USER="postgres"
PG_PASSWORD=""
MONGO_USER="admin"
MONGO_PASSWORD=""
COMMON_PASSWORD="${COMMON_PASSWORD:-}"

usage() {
  cat <<'USAGE'
用法:
  sh scripts/init_sample_data.sh [--project <name>] [--action init|clean|reset] [--rows <n>] [--password <pwd>]
                         [--pg-db <db>] [--pg-table <table>]
                         [--mongo-db <db>] [--mongo-collection <name>]

示例:
  sh scripts/init_sample_data.sh --project test --rows 200
  sh scripts/init_sample_data.sh --project test --action clean
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project|-p)
        PROJECT_NAME="${2:-}"; shift 2 ;;
      --rows)
        ROWS="${2:-}"; shift 2 ;;
      --action)
        ACTION="${2:-}"; shift 2 ;;
      --password)
        COMMON_PASSWORD="${2:-}"; shift 2 ;;
      --pg-db)
        PG_DB="${2:-}"; shift 2 ;;
      --pg-table)
        PG_TABLE="${2:-}"; shift 2 ;;
      --mongo-db)
        MONGO_DB="${2:-}"; shift 2 ;;
      --mongo-collection)
        MONGO_COLLECTION="${2:-}"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "[init-data] 未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

load_common_password() {
  if [ -n "$COMMON_PASSWORD" ]; then
    PG_PASSWORD="$COMMON_PASSWORD"
    MONGO_PASSWORD="$COMMON_PASSWORD"
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
    read -r -s -p "请输入统一密码(用于 pg/mongodb，必填): " input
    echo
    if [ -n "$input" ]; then
      PG_PASSWORD="$input"
      MONGO_PASSWORD="$input"
      return 0
    fi
    echo "[init-data] 统一密码不能为空，请重新输入" >&2
  done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[init-data] 缺少命令: $1" >&2
    exit 1
  }
}

container_by_service() {
  local project="$1"
  local service="$2"
  docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=$service" \
    --format '{{.ID}}' | head -n1
}

init_pg() {
  local pg_cid="$1"
  echo "[init-data] 初始化 PostgreSQL 数据库: ${PG_DB}"
  local db_exists
  db_exists="$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_cid" psql -t -A -U "$PG_USER" -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${PG_DB}';" | tr -d '[:space:]')"
  if [ "$db_exists" != "1" ]; then
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_cid" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -c "CREATE DATABASE ${PG_DB};" >/dev/null
  fi

  local table_sql
  read -r -d '' table_sql <<EOF_TABLE || true
CREATE TABLE IF NOT EXISTS ${PG_TABLE} (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  score INT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
EOF_TABLE
  docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_cid" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" -c "$table_sql" >/dev/null

  local insert_sql
  read -r -d '' insert_sql <<EOF_INSERT || true
INSERT INTO ${PG_TABLE}(name, score)
SELECT
  'user_' || substr(md5(random()::text), 1, 8),
  floor(random() * 101)::int
FROM generate_series(1, ${ROWS});
EOF_INSERT
  docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_cid" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" -c "$insert_sql" >/dev/null

  local count
  count="$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_cid" psql -t -A -U "$PG_USER" -d "$PG_DB" -c "SELECT COUNT(*) FROM ${PG_TABLE};")"
  echo "[init-data] PostgreSQL 完成: ${PG_DB}.${PG_TABLE} 当前总行数=${count}"
}

clean_pg() {
  local pg_cid="$1"
  echo "[init-data] 清理 PostgreSQL: ${PG_DB}.${PG_TABLE}"
  docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_cid" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -c "CREATE DATABASE ${PG_DB};" >/dev/null 2>&1 || true
  docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_cid" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" -c "DROP TABLE IF EXISTS ${PG_TABLE};" >/dev/null
}

init_mongo() {
  local mongo_cid="$1"
  local js
  read -r -d '' js <<EOF_JS || true
const dbName = "${MONGO_DB}";
const collName = "${MONGO_COLLECTION}";
const rows = ${ROWS};
const database = db.getSiblingDB(dbName);

const docs = [];
for (let i = 0; i < rows; i++) {
  docs.push({
    name: "user_" + Math.random().toString(16).slice(2, 10),
    score: Math.floor(Math.random() * 101),
    createdAt: new Date()
  });
}

if (docs.length > 0) {
  database.getCollection(collName).insertMany(docs);
}

print("mongo_count=" + database.getCollection(collName).countDocuments());
EOF_JS

  echo "[init-data] 初始化 MongoDB 数据库: ${MONGO_DB}"
  docker exec "$mongo_cid" mongosh \
    --quiet \
    --authenticationDatabase admin \
    -u "$MONGO_USER" \
    -p "$MONGO_PASSWORD" \
    --eval "$js"
}

clean_mongo() {
  local mongo_cid="$1"
  local js
  read -r -d '' js <<EOF_JS || true
const dbName = "${MONGO_DB}";
const collName = "${MONGO_COLLECTION}";
const database = db.getSiblingDB(dbName);
database.getCollection(collName).drop();
print("mongo_clean_done");
EOF_JS

  echo "[init-data] 清理 MongoDB: ${MONGO_DB}.${MONGO_COLLECTION}"
  docker exec "$mongo_cid" mongosh \
    --quiet \
    --authenticationDatabase admin \
    -u "$MONGO_USER" \
    -p "$MONGO_PASSWORD" \
    --eval "$js"
}

main() {
  parse_args "$@"
  prompt_common_password
  require_cmd docker

  if [ -z "$PROJECT_NAME" ]; then
    read -r -p "请输入项目名称(用于定位 tsdb/mongo 容器): " PROJECT_NAME
  fi
  if [ -z "$PROJECT_NAME" ]; then
    echo "[init-data] 项目名称不能为空" >&2
    exit 1
  fi
  case "$ACTION" in
    init|clean|reset) ;;
    *)
      echo "[init-data] --action 仅支持 init|clean|reset" >&2
      exit 1
      ;;
  esac
  if ! [[ "$ROWS" =~ ^[0-9]+$ ]] || [ "$ROWS" -le 0 ]; then
    echo "[init-data] --rows 必须是正整数" >&2
    exit 1
  fi

  local pg_cid mongo_cid
  pg_cid="$(container_by_service "$PROJECT_NAME" "tsdb")"
  mongo_cid="$(container_by_service "$PROJECT_NAME" "mongo")"

  if [ -z "$pg_cid" ]; then
    echo "[init-data] 未找到 PostgreSQL 容器(tsdb)，请确认项目名和容器状态" >&2
    exit 1
  fi
  if [ -z "$mongo_cid" ]; then
    echo "[init-data] 未找到 MongoDB 容器(mongo)，请确认项目名和容器状态" >&2
    exit 1
  fi

  case "$ACTION" in
    init)
      init_pg "$pg_cid"
      init_mongo "$mongo_cid"
      ;;
    clean)
      clean_pg "$pg_cid"
      clean_mongo "$mongo_cid"
      ;;
    reset)
      clean_pg "$pg_cid"
      clean_mongo "$mongo_cid"
      init_pg "$pg_cid"
      init_mongo "$mongo_cid"
      ;;
  esac
  echo "[init-data] 全部完成"
}

main "$@"
