# infra-base 基础设施底座
infra-base 是面向项目交付的通用基础设施底座，提供主流中间件与基础服务的标准化容器编排能力。通过统一网络与规范化部署方式，实现多套环境隔离与可预测运维，支撑研发、测试与演示环境的快速落地。

## 定位与价值
- 统一提供常见中间件与基础服务，降低重复建设与配置成本
- 按项目部署，多环境并行运行，满足开发、测试、演示等场景
- 统一可控网络，避免环境互相干扰，保障容器通信可预测
- 依赖集中化管理，减少启动与维护成本，缩短项目启动周期

## 使用方式
```sh
# 一键安装并启动
sh install.sh

# 卸载
sh uninstall.sh
```

## 业务服务一键部署
用于部署订单、设备管理等业务服务（提前提供镜像与 docker-compose 文件）。
```sh
# 指定项目名
sh deploy_services.sh -p <project> -f /path/to/order/docker-compose.yml
```

业务 compose 需绑定外部网络（建议使用环境变量）：
```yaml
networks:
  default:
    external: true
    name: ${NETWORK_NAME}
```

## 中间件与组件
- Nginx 入口与控制台
  容器：`nginx`（统一入口/静态首页/反向代理）
- 缓存与队列
  容器：`redis`（缓存/队列）
- 关系型数据库
  容器：`tsdb`（PostgreSQL，业务数据/时序数据存储）
- 对象存储
  容器：`minio`（S3 兼容对象存储与控制台）
- MQTT 消息服务
  容器：`emqx`（MQTT Broker 与管理控制台）
- API 网关
  容器：`apisix`（网关数据面）
  容器：`apisix-dashboard`（管理控制台）
  容器：`etcd`（配置存储）

## 管理端与外部接入地址
请直接访问infra-base控制台，页面包含所有服务的管理入口与外部接入端口：

- `http://<HOST>:80/`
- `http://<HOST>:3001/`
- `https://<HOST>:443/`

## 目录说明
```sh
infra-base
├── apisix                     # apisix 网关
│   ├── apisix
│   ├── apisix_conf
│   ├── dashboard_conf
│   └── docker-compose.yml     # apisix docker compose配置
├── nginx                      # nginx 入口与首页
│   ├── cert                   # 证书目录
│   ├── location.conf          # 路由/反向代理配置
│   ├── nginx.conf             # nginx 主配置
│   └── www
│       └── home_page          # 服务入口首页
│           ├── favicon.svg
│           ├── index.html
│           └── services.json
├── docker-compose.yml         # infra-base docker compose配置
├── docker_daemon.json         # docker daemon 配置模板
├── generate_services.sh       # 生成 services.json
├── install.sh                 # 一键安装与启动
├── start.sh                   # 启动脚本
└── uninstall.sh               # 停止并删除容器
```
