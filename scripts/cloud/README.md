# 低配 Ubuntu 云端验证与上线包

生产上线顺序、认证边界、systemd/Caddy、UFW/swap、发布/回滚和备份请先读
[云端上线手册](../../docs/cloud-deployment.md)。本目录的 `install.sh`、
`deploy_release.sh`、`backup.sh` 等脚本默认只做预检或 dry-run；不会连接
VPS/DNS，也不会在没有显式确认时改防火墙、swap 或服务 wiring。

当前目标只是在隔离测试环境验证 PostgreSQL 15+ migration 与约束，不是生产部署。

生产 `migrate.sh` 只执行 global `011_local_radar.sql`--`024_metadata_translation_leases.sql`
与 personal `001_personal_memory.sql`--`003_single_owner_auth.sql`；M1 的 global
`001`--`010` 仅供 disposable `verify_postgresql.sh`，迁移目录有未知/缺号 SQL 时会拒绝运行。

## 安全边界

- PostgreSQL 只监听服务器本机；不要向公网开放 5432。
- 云环境必须显式设置 `CLOUD_PUBLIC_DEPLOYMENT=1`、`PUBLIC_UNAUTHENTICATED_MODE=0`、`AUTH_REQUIRED_FOR_APP=1`、`PUBLISH_API_ENABLED=0`；任何匿名/local-development 值都会被 worker 拒绝。
- SSH 安全组只允许管理者当前出口 IP，优先使用密钥认证并禁用 root 密码登录。
- 不在仓库、命令历史或对话中保存密码、私钥、云 API key 或完整数据库 URL。
- `verify_postgresql.sh` 只接受经人工确认的空白、可丢弃数据库；发现任何用户 relation 会拒绝执行。
- 2 GiB 内存只用于 PostgreSQL、迁移和轻量测试；大型模型、搜索引擎、对象存储与应用服务不要同时部署在该实例。

## 顺序

1. 将仓库同步到服务器后运行只读预检：

   ```bash
   bash scripts/cloud/preflight_ubuntu.sh
   ```

2. 根据实际 Ubuntu 版本安装 PostgreSQL 15 或更高版本，并确认服务仅绑定 loopback。若没有 swap，先配置 1–2 GiB swap；不要在预检前盲目修改系统配置。

3. 创建一个独立空白测试数据库和最小权限测试角色。确认该库可丢弃后运行：

   ```bash
   export M1_DATABASE_URL='postgresql://USER@127.0.0.1/EMPTY_TEST_DATABASE'
   export M1_CONFIRM_DISPOSABLE_DATABASE=YES
   bash scripts/cloud/verify_postgresql.sh
   ```

4. 验证通过后再增加 ADV-013、PRI-012–013、EVA-025 的事务与并发 fixtures；在这些测试完成前，不把数据库切片标记为可发布。

## 2 GiB 实例初始约束

建议从 `max_connections=30`、`shared_buffers=256MB`、`work_mem=4MB`、`maintenance_work_mem=64MB` 起步，并依据实测调整。这里的数值是开发验证起点，不是生产容量结论。

生产部署配置已单独收敛到 `max_connections=20`、`shared_buffers=128MB`、
`work_mem=2MB`、`effective_cache_size=1GB`、`max_parallel_workers=2`、
`max_parallel_workers_per_gather=1`、`temp_buffers=8MB`、`temp_file_limit=256MB`，见
`deploy/cloud/postgresql/99-trend-exploring.conf`。本页的旧验证建议只针对
disposable migration 验证，不覆盖生产调优。

云 env 模板还必须把现有 LocalRuntime 指向系统 PostgreSQL Unix socket
（`LOCAL_PGSOCKET=/var/run/postgresql`、`LOCAL_PGPORT=5432`，global/personal
database 与 `/usr/bin`），并限制 `TRUSTED_PROXY_CIDRS` 为本机 Caddy 的
`127.0.0.1/32,::1/128`。`backup.sh` 对 global 与 personal 两库分别加密，
`verify_backup.sh` 只读校验 manifest/checksum/GPG packet，`restore_backup.sh`
默认只做 disposable restore 计划。
