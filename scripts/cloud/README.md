# 低配 Ubuntu 云端验证

当前目标只是在隔离测试环境验证 PostgreSQL 15+ migration 与约束，不是生产部署。

## 安全边界

- PostgreSQL 只监听服务器本机；不要向公网开放 5432。
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
