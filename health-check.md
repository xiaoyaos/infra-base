# infra-base 健康检查说明

`scripts/check.sh` 用于部署后的只读验收，不会修改配置、不会重启服务、不会写入业务数据。

## 1. 使用方式

```bash
sh scripts/check.sh --project <project>
```

可选参数：
- `--strict`：有失败项时返回非 0（CI 推荐）
- `--report <path>`：指定报告输出路径

示例：

```bash
sh scripts/check.sh --project iedp --strict
sh scripts/check.sh --project iedp --report /tmp/iedp_check.md
```

## 2. 检查边界

包含：
- 容器是否存在且运行
- 已启用服务端口是否监听
- PostgreSQL / MongoDB / MinIO 基础连通性
- `nginx/www/home_page/services.json` 文件存在性
- 输出验收报告

不包含：
- 自动修复（不重启、不改配置）
- 业务深度压测
- 数据写入/清理

## 3. 输出与退出码

- 控制台会输出 `PASS/WARN/FAIL` 明细
- 报告默认输出到 `reports/check_时间戳.md`
- 返回码：
  - `0`：无失败项
  - `1`：存在失败项

## 4. 结果处理建议

1. 先修复 `FAIL` 项  
2. 对 `WARN` 项确认是否可接受  
3. 修复后再次执行 `scripts/check.sh` 直至通过  
