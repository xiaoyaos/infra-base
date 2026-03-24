# infra-base 基础设施底座
infra-base 用于统一提供项目运行所需的基础中间件与网关能力，支持按 `compose project` 隔离多套环境。

## 核心入口
```sh
# 统一入口（交互式）
sh infractl.sh
```

## infractl.sh 说明
根目录 `infractl.sh` 为统一外部入口，支持：
- `1) 基础包安装（base）`
- `2) 生成迁移包（migration backup）`
- `3) 迁移包安装（full）`
- `4) 数据恢复（restore）`
- `5) 健康检查（check）`
- `6) 启动基础服务（start）`
- `7) 卸载基础服务（uninstall）`
- `8) 部署业务服务（deploy services）`
- `9) 初始化样例数据`

关键交互行为：
- 模式选择：统一数字菜单交互
- 项目名：会校验是否冲突（已存在会要求重输）
- 统一密码：必填，写入 `.env` 的 `COMMON_PASSWORD`
- 服务创建：逐容器选择是否创建
- 端口输入：仅对“选择创建”的容器输入端口，并实时检测占用
- base/full 安装时会写入 `/etc/profile.d/custom.sh`，注册 `INFRA_BASE_HOME=<infra-base根目录>`

## 业务网络要求
业务服务 compose 需要挂入 infra-base 外部网络（`NETWORK_NAME=infra-base-<project>`）：

```yaml
networks:
  default:
    external: true
    name: ${NETWORK_NAME}
```

## 迁移相关
迁移打包/恢复流程请查看：
- [migration.md](./migration.md)

说明：
- 迁移包会包含 infra-base 根目录下的 `services/` 目录
- `full` 模式会将迁移包内 `services/` 恢复到当前 infra-base 根目录

健康检查/验收说明请查看：
- [health-check.md](./health-check.md)

## 主要组件
- `nginx`：统一入口与静态资源
- `redis`：缓存/队列
- `tsdb`：PostgreSQL/TimescaleDB
- `minio`：对象存储
- `mongo`：文档数据库
- `emqx`：MQTT
- `apisix` + `apisix-dashboard` + `etcd`：网关与配置

## 目录说明
```sh
infra-base
├── apisix/                    # APISIX 相关配置与 compose
├── config/                    # 组件配置目录
├── dockerx/                   # docker x 扩展与兼容命令
├── nginx/                     # nginx 配置与静态页面
├── scripts/                   # 非入口脚本
│   ├── install.sh             # 安装主流程(base/full/restore)
│   ├── start.sh               # 启动入口
│   ├── uninstall.sh           # 卸载入口
│   ├── deploy_services.sh     # 业务服务部署入口
│   ├── migration.sh           # 交互式迁移打包
│   ├── restore.sh             # 交互式恢复
│   ├── init_sample_data.sh    # 测试数据初始化/清理
│   ├── generate_services.sh   # 生成 services.json
│   └── check.sh               # 健康检查/验收脚本
├── migration_bundle/          # 迁移包输出目录（按版本）
├── migration.md               # 迁移操作手册
├── health-check.md            # 健康检查说明
├── docker-compose.yml         # infra-base compose
├── docker_daemon.json         # docker daemon 配置模板
└── infractl.sh                # 根目录唯一外部入口
```
