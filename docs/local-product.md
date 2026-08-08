# Local product vertical slice

当前仓库已经有一个可启动的本地产品切片：PostgreSQL 15.18 数据库、Ruby WEBrick API 和静态 Radar 前端。它用于把 M5 contract 接到真实的本地存储与 HTTP 读取链路，仍然不是生产部署。

## 启动

`run_product.sh` 会在 `/private/tmp/trend-exploring-pg15` 创建并启动一个仅供本地 staging 使用的 PostgreSQL 15 disposable instance（socket `/private/tmp/trend-exploring-pg-socket`、端口 `55433`），然后启动 API。也可以手动运行 `scripts/local/start_postgres.sh`，或用 `LOCAL_PSQL`、`LOCAL_PGHOST`、`LOCAL_PGPORT`、`LOCAL_PGDATABASE`、`LOCAL_PGUSER` 覆盖连接参数。

```bash
ruby scripts/local/bootstrap_radar.rb
ruby scripts/local/start_radar.rb
```

也可以直接运行：

```bash
bash scripts/local/run_product.sh
```

然后打开 <http://127.0.0.1:3000>。API 入口：

- `GET /api/health`：数据库与 PostgreSQL 版本
- `GET /api/radar`：当前 published snapshot 和卡片
- `POST /api/radar/publish`：staging-only 的完整 snapshot + cards 原子发布入口

服务启动后可用另一终端运行 HTTP smoke：

```bash
ruby scripts/local/smoke_radar.rb
```

## 本地切片边界

- PostgreSQL 表为 `local_radar_snapshot` 与 `local_radar_card`，仅用于 staging vertical slice。
- 后端通过 `psql` CLI 访问数据库，不把密码、URL 或云凭据写入仓库。
- 前端只读取 public snapshot，不读取个人记忆；页面明确显示 snapshot、watermark、rights epoch 和 evidence boundary。
- M5 的实时流、生产 auth/provider、CDN、真实浏览器和治理条件仍需独立环境验证。

外部条件的输入清单和执行顺序见 [production-unblock-runbook.md](production-unblock-runbook.md)。
