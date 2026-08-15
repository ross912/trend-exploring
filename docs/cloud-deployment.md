# Ubuntu 24.04 云端上线手册（zixin.space）

本手册只描述上线包和验收顺序；本次开发不连接 VPS、不改 DNS。目标机器为 2 vCPU、2 GiB RAM、40 GiB 磁盘，应用由专用的 `trendexploring` 系统账号运行。

DNS 由人工操作单独完成：添加 `A zixin.space -> 116.62.118.251`（如使用
IPv6 再单独评估 AAAA），等待解析确认后再让 Caddy 申请证书。仓库脚本不
调用 DNS API，也不假设解析已经生效。

## 安全边界

- 公网只允许 TCP `22/80/443`。Caddy 监听公网并负责 `zixin.space` 的 TLS；应用只绑定 `127.0.0.1:3000`，PostgreSQL 只监听 `localhost`/Unix socket。
- 首页、静态资源、`/login`、登录/恢复 POST 和最小 `/api/livez` 可公开；`/app`、所有其他数据 API（包括 `/api/health`）、管理/发布/付费动作必须由后端会话认证。Caddy 不叠加 BasicAuth，避免出现两套凭据。
- `/etc/trend-exploring/trend-exploring.env` 是 root:trendexploring、权限 `0600` 的本地文件。不要把数据库 URL、会话密钥、GPG 私钥或恢复码放进仓库、argv、日志或备份 manifest。
- `CLOUD_PUBLIC_DEPLOYMENT=1`、`PUBLIC_UNAUTHENTICATED_MODE=0`、`AUTH_REQUIRED_FOR_APP=1`、`PUBLISH_API_ENABLED=0` 是云端 fail-closed 合同。任一旧 local/anonymous 值都会使 worker 拒绝启动。
- 先由后端/auth agent 配置单账号登录密码、恢复码哈希和 session/cookie secret，再把引用写入权限为 0600 的 env/secrets 文件；本上线包不生成、显示或传输这些值。

## 第一次安装

在服务器控制台确认有可用的 SSH 会话和云厂商救援入口，然后执行只读预检：

```bash
sudo bash scripts/cloud/preflight_ubuntu.sh --strict
```

strict 预检会阻止低于约 1.5 GiB RAM、1 GiB swap、10 GiB root free 或
root 使用率达到 75% 的主机；非 strict 模式只警告。容量门禁不替代上线后
的 OOM/journal 观察。

安装包不会自动启动服务，也不会覆盖已有 env/Caddy/PostgreSQL 配置：

```bash
sudo bash scripts/cloud/install.sh --repo-root /path/to/checkout
sudoedit /etc/trend-exploring/trend-exploring.env
sudo chmod 600 /etc/trend-exploring/trend-exploring.env
```

模板同时设置应用实际读取的 `LOCAL_PGSOCKET=/var/run/postgresql`、
`LOCAL_PGPORT=5432`、`LOCAL_PGUSER`、`LOCAL_PGDATABASE`、
`PERSONAL_PGDATABASE` 与 `PG_BIN`；只设置 `DATABASE_URL` 不足以让现有
LocalRuntime 切换到系统 PostgreSQL。

### PostgreSQL role/database bootstrap

安装包不会偷偷创建数据库。先查看幂等计划，再以 root（脚本会通过本机
peer 调用 `postgres` OS 账号）确认创建一个非 superuser role 与两个数据库：

```bash
sudo bash scripts/cloud/bootstrap_postgresql.sh --dry-run
sudo bash scripts/cloud/bootstrap_postgresql.sh --confirm
```

脚本拒绝接收密码、拒绝重分配已有数据库 owner、拒绝修改已有 superuser；
只授予 role `CONNECT,TEMP` 及 public schema 的 `USAGE,CREATE`。完成后再跑
strict preflight 与 migration。

预检要求 Ruby >= 3.1 与固定 WEBrick 版本（模板默认为 `1.8.1`）。应用的 `Gemfile.lock` 由 integration 任务按该值锁定；本上线包不擅自改动应用依赖。

### 防火墙与 swap（显式确认）

先看计划，确认当前 SSH 出口不会被锁死：

```bash
sudo bash scripts/cloud/configure_ufw.sh --dry-run
sudo bash scripts/cloud/configure_swap.sh --size 2G --dry-run
sudo bash scripts/cloud/preflight_ubuntu.sh --strict   # 列出 unexpected UFW ALLOW 并 fail-closed
```

确认后才执行实际变更：

```bash
sudo bash scripts/cloud/configure_ufw.sh --confirm
sudo bash scripts/cloud/configure_swap.sh --size 2G --confirm
```

swap 脚本只接受 1G/2G，检测到已有活动 swap 或同名文件时不覆盖；UFW 只写入 22/80/443 规则。若已有其他 ALLOW，预检和 `configure_ufw.sh --confirm` 都会列出并停止，不会自动删除，需人工执行 `ufw status numbered` 后清理。两者都没有隐式确认路径。

## 发布与迁移

`deploy_release.sh` 建立不可变 release 目录，运行 strict preflight，先做加密备份，再执行带 PostgreSQL advisory lock 的迁移，最后用临时 symlink + `mv -T` 原子切换 `current`。任何前置步骤失败都不会切换版本；没有 force migration 选项。

```bash
sudo bash scripts/cloud/deploy_release.sh --source /path/to/checkout
sudo systemctl restart caddy  # 首次将 caddy 加入 trendexploring 组后刷新组权限
```

迁移 timer 默认未 enable；需要变更前先完成备份审阅，再显式创建 `/etc/trend-exploring/enable-migrations` 或安装时使用 `--enable-migrations`。迁移脚本分别在 global 与 personal 数据库按受控清单执行：global 只运行 `011_local_radar.sql` 到 `024_metadata_translation_leases.sql`，personal 只运行 `001_personal_memory.sql` 到 `003_single_owner_auth.sql`，各自持有 advisory lock，完成后释放。`schema/postgres/001_m1_core.sql`--`010_m1_data_domain.sql` 是 M1 契约/验证用 schema，只能用于 disposable `verify_postgresql.sh` 演练，不会进入 runtime DB；迁移目录出现未知或缺号的 numbered SQL 会 fail-closed。

应用/auth agent 先写入 `CLOUD_IDENTITY_PEPPER`、`CLOUD_SESSION_PEPPER`，并创建单账号密码、恢复码哈希；然后按以下顺序首次启动：

```bash
sudo systemctl start postgresql
sudo bash scripts/cloud/bootstrap_postgresql.sh --confirm
sudo bash scripts/cloud/run_as_app_user.sh scripts/cloud/run_migration.sh
sudo bash scripts/cloud/run_as_app_user.sh ruby scripts/local/configure_cloud_owner.rb  # 仅 SSH/TTY，密码和恢复码不进 argv
sudo systemctl restart caddy
sudo systemctl start trend-exploring-server.service
sudo systemctl start trend-exploring-collect.timer trend-exploring-cycle.timer trend-exploring-translation.timer
sudo bash scripts/cloud/status.sh
```

`run_migration.sh` 使用全局批处理锁与 PostgreSQL advisory lock；账号未配置时 web server 会拒绝启动。

只回滚应用代码，不回滚数据库：

```bash
sudo bash scripts/cloud/rollback_app.sh --to 20260815T120000Z-a1b2c3d4e5f6 --confirm
```

回滚命令不会调用 `pg_restore`、删除表或撤销迁移。数据恢复必须走单独的离线演练与人工审批。

## 备份与保留

备份脚本分别对 global 与 personal/auth 两个 PostgreSQL 数据库执行 `pg_dump --format=custom`，再使用运维提供的 GPG 公钥加密为 `global.dump.gpg` 与 `personal.dump.gpg`，manifest 记录两者 checksum；缺任一数据库 URL 或 `CLOUD_BACKUP_GPG_RECIPIENT` 时生产备份会 fail-closed。默认保留 10 份，允许范围严格为 7–14 份，并支持校验/off-host hook：

```bash
sudo bash scripts/cloud/run_as_app_user.sh scripts/cloud/run_backup.sh # 生产加密备份（含全局批处理锁）
sudo env CLOUD_DRY_RUN=1 bash scripts/cloud/run_as_app_user.sh scripts/cloud/run_backup.sh # 只展示目标与清理计划
sudo bash scripts/cloud/run_as_app_user.sh scripts/cloud/verify_backup.sh /var/backups/trend-exploring/20260815T120000Z
sudo bash scripts/cloud/run_as_app_user.sh scripts/cloud/restore_backup.sh /var/backups/trend-exploring/20260815T120000Z --dry-run
```

校验脚本只读检查 manifest、两份 checksum 和 GPG packet；`CLOUD_BACKUP_RESTORE_HOOK` 只记录在 manifest，由人工先执行 `verify_backup.sh` 再调用；`restore_backup.sh` 默认只规划，`--confirm` 也只创建两个全新的 disposable 数据库，拒绝覆盖/删除现有库。off-host hook 只收到已加密备份目录路径，输出被丢弃；hook 需要自行做对象存储/异地主机的加密传输与可恢复性校验。保留清理由显式日期目录组成，不触碰备份根目录之外的文件。

每日 03:00 的 `trend-exploring-backup.timer` 默认不 enable；先配置 GPG
recipient、手工执行一次 backup/verify/disposable restore 演练，再显式开启：

```bash
sudoedit /etc/trend-exploring/trend-exploring.env  # CLOUD_BACKUP_GPG_RECIPIENT
sudo bash scripts/cloud/run_as_app_user.sh scripts/cloud/run_backup.sh
sudo bash scripts/cloud/run_as_app_user.sh scripts/cloud/verify_backup.sh /var/backups/trend-exploring/<STAMP>
sudo bash scripts/cloud/run_as_app_user.sh scripts/cloud/restore_backup.sh /var/backups/trend-exploring/<STAMP> --dry-run
sudo systemctl enable --now trend-exploring-backup.timer
```

安装器只有传入 `--enable-backups` 才会 enable timer；未配置 recipient
时备份脚本 fail-closed，不会产生明文 dump。

## systemd/Caddy 运行面

安装包提供 `server`、`collect`、`cycle`、`translation` 四个 worker、可人工开启的 `migration` unit/timer，以及默认关闭的 encrypted `backup` unit/timer。collection 只在 Asia/Shanghai 07:55 与 18:55 运行（Persistent+jitter），不是每 15 分钟轮询；所有批处理共享全局 flock，补跑时只允许一个批次进入。`cycle` 固定传入 `--skip-ingest`，消费最近一次 immutable collection，避免重复 ingest。

systemd 对 server 设置 `MemoryHigh=400M/MemoryMax=512M/TasksMax=32`，对
collect/cycle/translation/migration/backup 设置 `MemoryHigh=512M/MemoryMax=768M`、
`TasksMax=64`、`LimitNOFILE=4096`；这与 2 vCPU/2 GiB VPS 的 PostgreSQL
低内存 profile 一起工作，仍需上线后观察 OOM/journal。

worker 不使用 shell `exec`，而是后台启动子进程、等待并在 SIGTERM 时发送 TERM 后 drain；退出时总是释放 per-service lock。per-service pid lock 在进程已经不存在时可安全回收；lease/stale recovery 可由 `CLOUD_STALE_RECOVERY_COMMAND` 注入，凭据不得出现在命令行。

Caddyfile 的路径规则是 fail-closed：只有 landing/assets、登录/恢复提交和最小 `/api/livez` 进入相应后端；`/app` 与所有其他 `/api`（包括 `/api/health`）等私有前缀统一反代，由后端会话判定；`/api/readyz` 仅本机监控直接访问，外部请求显式 404；未匹配路径也交给 backend，由 backend 按会话返回 302/401/404，避免新增静态资产意外公开。登录请求使用更小 body 上限和短超时作辅助限制，真正的 per-IP/account 限流必须由后端执行。代理全局 body 上限 2 MiB、连接/读写超时，并写入 noindex 与安全 headers。标准 Caddy 自动签发 `zixin.space` 证书，DNS/A 记录和 VPS 公网地址由上线操作单独完成。

## 验收清单

```bash
sudo bash scripts/cloud/status.sh
sudo ss -ltnp                       # 只应见 22/80/443，以及 loopback 的 3000/5432
sudo ufw status verbose
sudo -u trendexploring bash -c 'test "$(stat -c %a /etc/trend-exploring/trend-exploring.env)" = 600'
curl --fail --max-time 5 https://zixin.space/api/livez
curl -i https://zixin.space/             # landing 可读
curl -i https://zixin.space/login        # 登录页可读
curl -i https://zixin.space/app          # 未登录必须 302 -> /login，由后端返回
curl -i https://zixin.space/api/health   # 未登录必须 401/403，由后端返回
```

观察 `journalctl -u trend-exploring-server -u trend-exploring-collect -u trend-exploring-cycle -u trend-exploring-translation`，确认没有 DATABASE_URL、cookie secret、GPG 私钥或恢复码。Caddy 和应用日志由 `/etc/logrotate.d/trend-exploring` 分别按日压缩，最多保留 14 份。

卸载只移除 unit、Caddy/logrotate wiring，默认保留 `/etc/trend-exploring`、release、数据库和加密备份：

```bash
sudo bash scripts/cloud/uninstall.sh --dry-run
sudo bash scripts/cloud/uninstall.sh --confirm
```
