#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/nginx/www/home_page/services.json"

BASE_COMPOSE="$SCRIPT_DIR/docker-compose.yml"
APISIX_COMPOSE="$SCRIPT_DIR/apisix/docker-compose.yml"

if [ ! -f "$BASE_COMPOSE" ]; then
  echo "[generate] 未找到 $BASE_COMPOSE" >&2
  exit 1
fi
if [ ! -f "$APISIX_COMPOSE" ]; then
  echo "[generate] 未找到 $APISIX_COMPOSE" >&2
  exit 1
fi

GENERATED_AT="$(date +"%Y-%m-%d %H:%M:%S %Z")"

awk -v generated_at="$GENERATED_AT" '
function port_protocol(port) {
  if (port==80 || port==3001) return "http";
  if (port==443 || port==9443) return "https";
  if (port==6379) return "redis";
  if (port==5432) return "postgres";
  if (port==9000 || port==9001 || port==18083 || port==8081 || port==9180 || port==9080 || port==2379) return "http";
  if (port==1883) return "tcp";
  if (port==8883) return "ssl";
  if (port==8083) return "ws";
  if (port==8084) return "wss";
  return "tcp";
}
function port_desc(svc, port) {
  if (svc=="nginx" && port==80) return "HTTP 入口";
  if (svc=="nginx" && port==3001) return "HTTP 备用/兼容端口";
  if (svc=="nginx" && port==443) return "HTTPS 入口";
  if (svc=="redis" && port==6379) return "缓存/队列客户端连接";
  if (svc=="tsdb" && port==5432) return "数据库客户端连接";
  if (svc=="minio" && port==9001) return "控制台/管理界面";
  if (svc=="minio" && port==9000) return "S3 API 访问";
  if (svc=="emqx" && port==18083) return "控制台/管理界面";
  if (svc=="emqx" && port==1883) return "MQTT TCP";
  if (svc=="emqx" && port==8883) return "MQTT TLS";
  if (svc=="emqx" && port==8083) return "MQTT WebSocket";
  if (svc=="emqx" && port==8084) return "MQTT WSS";
  if (svc=="emqx" && port==8081) return "HTTP API/监控";
  if (svc=="apisix-dashboard" && port==9000) return "Dashboard 管理界面";
  if (svc=="apisix" && port==9180) return "管理 API";
  if (svc=="apisix" && port==9080) return "网关 HTTP 入口";
  if (svc=="apisix" && port==9443) return "网关 HTTPS 入口";
  if (svc=="etcd" && port==2379) return "客户端/API 访问";
  return "服务端口";
}
function port_category(svc, port) {
  if ((svc=="minio" && port==9001) || (svc=="emqx" && port==18083) || (svc=="apisix-dashboard" && port==9000) || (svc=="apisix" && port==9180)) return "management";
  return "access";
}
function add_port(svc, host_port, container_port) {
  if (!(svc in seen)) { seen[svc]=1; order[++order_n]=svc; }
  cat=port_category(svc, container_port);
  key=svc SUBSEP cat;
  proto=port_protocol(container_port);
  desc=port_desc(svc, container_port);
  item=host_port "|" container_port "|" proto "|" desc;
  if (index(";" ports[key] ";", ";" item ";")==0) {
    ports[key]=ports[key] item ";";
  }
}
BEGIN { in_ports=0; svc=""; }
{
  if ($0 ~ /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*$/) {
    line=$0;
    sub(/^[[:space:]]{2}/, "", line);
    sub(/:[[:space:]]*$/, "", line);
    svc=line;
    in_ports=0;
    next;
  }
  if ($0 ~ /^[[:space:]]{4}ports:[[:space:]]*$/) {
    in_ports=1;
    next;
  }
  if (in_ports) {
    if ($0 !~ /^[[:space:]]{6}-/) { in_ports=0; next; }
    line=$0;
    gsub(/^[[:space:]]{6}-[[:space:]]*/, "", line);
    gsub(/"/, "", line);
    gsub(/[[:space:]]+/, "", line);

    # 兼容 9000:9000/tcp 或 9000
    host=""; cont="";
    n=split(line, parts, ":");
    if (n >= 2) {
      host=parts[1];
      cont=parts[2];
    } else {
      cont=parts[1];
    }
    sub(/\/.*/, "", cont);

    if (cont ~ /^[0-9]+$/) {
      add_port(svc, host, cont);
    }
  }
}
END {
  print "{";
  print "  \"generated_at\": \"" generated_at "\",";
  print "  \"services\": [";

  first=1;
  # access entries
  for (i=1; i<=order_n; i++) {
    svc=order[i];
    key=svc SUBSEP "access";
    if (!(key in ports)) continue;
    if (!first) print ",";
    first=0;
    print "    {";
    print "      \"name\": \"" svc "\",";
    print "      \"category\": \"access\",";
    print "      \"ports\": [";
    n=split(ports[key], items, ";");
    fp=1;
    for (j=1; j<=n; j++) {
      if (items[j]=="") continue;
      split(items[j], parts, "|");
      if (!fp) print ",";
      fp=0;
      map=(parts[1] != "" ? parts[1] : "-") "->" parts[2];
      print "        {\"host_port\": \"" parts[1] "\", \"container_port\": \"" parts[2] "\", \"mapping\": \"" map "\", \"protocol\": \"" parts[3] "\", \"desc\": \"" parts[4] "\"}";
    }
    print "      ]";
    print "    }";
  }

  # management entries
  for (i=1; i<=order_n; i++) {
    svc=order[i];
    key=svc SUBSEP "management";
    if (!(key in ports)) continue;
    if (!first) print ",";
    first=0;
    print "    {";
    print "      \"name\": \"" svc "\",";
    print "      \"category\": \"management\",";
    print "      \"ports\": [";
    n=split(ports[key], items, ";");
    fp=1;
    for (j=1; j<=n; j++) {
      if (items[j]=="") continue;
      split(items[j], parts, "|");
      if (!fp) print ",";
      fp=0;
      map=(parts[1] != "" ? parts[1] : "-") "->" parts[2];
      print "        {\"host_port\": \"" parts[1] "\", \"container_port\": \"" parts[2] "\", \"mapping\": \"" map "\", \"protocol\": \"" parts[3] "\", \"desc\": \"" parts[4] "\"}";
    }
    print "      ]";
    print "    }";
  }

  print "  ]";
  print "}";
}
' "$BASE_COMPOSE" "$APISIX_COMPOSE" > "$OUTPUT_FILE"

echo "[generate] 已生成 $OUTPUT_FILE"
