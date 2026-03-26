# infra-base 基础设施底座

infra-base 用于统一提供项目运行所需的基础中间件与网关能力。

## 使用规则

- 唯一外部入口：`sh infractl.sh`
- 所有日常操作都从 `infractl.sh` 菜单进入
- `scripts/` 下脚本属于内部实现，不作为对外操作入口
- 环境隔离边界是“目录 + compose project”
  - 容器、网络按 `project` 区分
  - 数据目录按当前 infra-base 目录区分
- 如果在同一台机器上做迁移验证，建议使用独立目录
  - 例如源目录 `/home/infra-base`
  - 恢复目录 `/home/infra-restore`
- 迁移包目录可以单独放置，通过菜单输入目录指向即可，不要求与当前 infra-base 目录相同

## 统一入口

```sh
sh infractl.sh
```

菜单功能：

1. `基础包安装（base）`
2. `生成迁移包（migration backup）`
3. `迁移包安装（full）`
4. `数据恢复（restore）`
5. `健康检查（check）`
6. `启动基础服务（start）`
7. `卸载基础服务（uninstall，不含业务服务）`
8. `部署业务服务（deploy services，独立管理）`
9. `初始化样例数据`


## 安装基础环境

适用场景：

- 当前目录是一套全新的 infra-base
- 只想先把基础中间件启动起来

操作步骤：

1. 进入 infra-base 根目录
2. 执行 `sh infractl.sh`
3. 选择 `1) 基础包安装（base）`
4. 输入 `project` 名称
5. 输入统一密码
6. 按提示选择需要启用的服务和端口
7. 如当前机器没有 Docker，脚本会自动安装
8. 安装完成后脚本会自动启动基础服务
9. 返回菜单后执行 `5) 健康检查（check）`

交互说明：

- 已启用的服务才会继续询问端口
- 回车会采用当前值或默认值
- 端口会实时做占用校验
- `COMMON_PASSWORD` 和服务开关会保存到 `.infra/projects/<project>/.env`

## 补装服务/重建服务

适用场景：

- 已经安装过某个 `project`
- 当时漏选了某些服务
- 某些服务需要强制重建

操作步骤：

1. 执行 `sh infractl.sh`
2. 选择 `1) 基础包安装（base）`
3. 输入已有的 `project` 名称
4. 看到“是否对该项目执行补装/更新”时输入 `Y`
5. 按当前需要重新选择服务
6. 如果只是补装漏选服务，强制重建列表直接回车
7. 如果要重建指定服务，按提示输入服务名，例如 `redis,nginx`
8. 安装脚本会复用当前 project 配置，并自动调用启动流程

说明：

- 已存在 project 会自动带出当前服务开关和端口作为默认值
- 同 project 更新时，保留自身已占用端口是允许的
- 适合用来补装 `nginx/apisix`、重建 `redis` 等场景

## 整体迁移

适用场景：
- 把当前环境迁移到另一台机器

操作步骤：

1. 在源环境目录执行 `sh infractl.sh`
2. 选择 `2) 生成迁移包（migration backup）`
3. 按提示输入项目名称、统一密码、版本号、描述
4. 选择备份模式
   - `raw`：直接打包 `production_data`
   - `logical`：导出 PostgreSQL / MongoDB / MinIO 逻辑备份
   - `both`：同时保留两种方式，推荐
5. 选择是否导出离线镜像
6. 勾选要备份的数据项

输出结果：

- 迁移包目录：`migration_bundle/<version>`
- 元数据文件：`manifest.json`
- 校验文件：`checksums.sha256`

选择建议：

1. 不确定时，优先选择 `both`
2. 恢复时默认优先选 `logical`
3. 只有在确认源环境和目标环境高度一致时，再使用 `raw`

密码规则：

- `raw` 恢复必须使用源环境统一密码
- `logical` 恢复使用目标环境当前输入的统一密码

## 迁移包安装（full）

适用场景：

- 新机器第一次恢复

操作步骤：

1. 打包`migration_bundle/<version>`并上传至目标机器
2. 解压迁移包
3. 执行 `sh infractl.sh`
4. 选择 `3) 迁移包安装（full）`
5. 输入迁移包目录
6. 输入新的 `project` 名称
7. 按提示选择服务、端口、恢复源
8. 完成后执行 `5) 健康检查（check）`

说明：

- `full` 会先准备基础环境，再恢复数据
- `logical` 恢复会先启动容器再导入数据
- `raw` 恢复会先导入数据，再启动容器
- 迁移包内 `services/` 目录也会恢复到当前目录

## ~~数据恢复（restore）慎用~~

适用场景：

- 当前目录里的基础环境已经存在
- 只想重新导入数据，不重新做整套安装

操作步骤：

1. 进入目标 infra-base 目录
2. 执行 `sh infractl.sh`
3. 选择 `4) 数据恢复（restore）`
4. 输入迁移包目录
5. 选择恢复源
6. 输入当前环境对应的 `project`
7. 确认覆盖恢复
8. 完成后执行 `5) 健康检查（check）`

重要说明：

- `restore` 会覆盖当前目录下的数据
- 恢复前会自动备份当前 `production_data` 到 `migration_bundle/pre_restore_backup/`
- 同机验证时仍然建议使用独立目录，不建议把多套恢复环境长期混放在同一目录下

## 健康检查

用途：

- 部署后的只读验收
- 不修改配置
- 不重启服务
- 不写入业务数据

操作步骤：

1. 执行 `sh infractl.sh`
2. 选择 `5) 健康检查（check）`
3. 输入 `project` 名称

检查内容：

- 已启用服务的容器是否存在且运行
- 已启用服务端口是否监听
- PostgreSQL / MongoDB / MinIO 基础连通性
- `nginx/www/home_page/services.json` 是否存在
- 生成验收报告

输出位置：

- 默认报告目录：`reports/`

## 启动基础服务

适用场景：

- 已经装好环境，只想重新启动服务
- 修改了配置后想重新起容器

操作步骤：

1. 执行 `sh infractl.sh`
2. 选择 `6) 启动基础服务（start）`
3. 输入 `project` 名称

说明：

- 会根据 `.infra/projects/<project>/.env` 中的启用项启动对应服务
- 如果配置哈希变化，会自动更新变更过的服务

## 卸载基础服务

适用场景：

- 想删除某个 project 对应的基础环境和网关

操作步骤：

1. 执行 `sh infractl.sh`
2. 选择 `7) 卸载基础服务（uninstall，不含业务服务）`
3. 输入 `project` 名称

边界说明：

- 只会卸载 infra-base 基础容器
- 不会自动删除通过 `deploy services` 部署的业务服务
- 如果网络删除失败，通常表示还有业务服务占用该网络

## 部署业务服务

适用场景：

- 基础环境已经启动
- 业务服务需要接入 infra-base 外部网络

业务 compose 要求：

```yaml
networks:
  default:
    external: true
    name: ${NETWORK_NAME}
```

最小示例：

```yaml
services:
  hello:
    image: busybox:1.36
    command: sh -c "sleep infinity"

networks:
  default:
    external: true
    name: ${NETWORK_NAME}
```

操作步骤：

1. 执行 `sh infractl.sh`
2. 选择 `8) 部署业务服务（deploy services，独立管理）`
3. 输入 project 名称
4. 输入一个或多个业务 compose 文件路径

边界说明：

- 业务服务会复用 `COMPOSE_PROJECT_NAME=<project>`
- 业务服务需要在各自 compose 目录自行 `docker compose down`
- `7) 卸载基础服务` 不会自动清理业务服务

## 关键路径与文件

- 项目级配置：`.infra/projects/<project>/.env`
- 迁移包目录：`migration_bundle/<version>`
- 恢复前备份：`migration_bundle/pre_restore_backup/`
- 验收报告：`reports/`
- 业务服务目录：`services/`

## 目录说明

```sh
infra-base
├── apisix/                    # APISIX 相关配置与 compose
├── config/                    # 组件配置目录
├── dockerx/                   # docker x 扩展与兼容命令
├── nginx/                     # nginx 配置与静态页面
├── scripts/                   # 内部实现脚本（不作为外部入口）
├── migration_bundle/          # 迁移包输出目录
├── reports/                   # 健康检查报告
├── docker-compose.yml         # infra-base compose
├── docker_daemon.json         # docker daemon 配置模板
└── infractl.sh                # 唯一外部入口
```