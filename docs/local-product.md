# Local product vertical slice

当前仓库已经有一个可启动的本地产品切片：PostgreSQL 15.18 数据库、Ruby WEBrick API 和静态 Radar 前端。它用于把 M5 contract 接到真实的本地存储与 HTTP 读取链路，仍然不是生产部署。

## 启动

`run_product.sh` 会在 `/private/tmp/trend-exploring-pg15` 创建并启动一个仅供本地 staging 使用的 PostgreSQL 15 disposable instance（socket `/private/tmp/trend-exploring-pg-socket`、端口 `55433`），然后启动 API。也可以手动运行 `scripts/local/start_postgres.sh`，或用 `LOCAL_PSQL`、`LOCAL_PGHOST`、`LOCAL_PGPORT`、`LOCAL_PGDATABASE`、`LOCAL_PGUSER` 覆盖连接参数。

默认启动会从 `config/sources.json` 采集多区域、多语言的公开 RSS/Atom，并发布一个新的 live snapshot。当前矩阵覆盖中国大陆、全球、亚洲、欧洲、北美，语言包括中文和英文；前端界面为中文，英文条目明确标注为英文原文，不假装完成翻译。若当前网络不可用，可使用 `LOCAL_INGEST_LIVE=0 bash scripts/local/run_product.sh` 只启动已有本地数据。

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
- `GET /api/radar`：当前 published snapshot、独立的 `trends`、`cards` 新闻和 `sources` 来源矩阵
- `POST /api/radar/publish`：staging-only 的完整 snapshot + cards + trends 原子发布入口

服务启动后可用另一终端运行 HTTP smoke：

```bash
ruby scripts/local/smoke_radar.rb
```

## 本地切片边界

- PostgreSQL 表为 `local_radar_snapshot`、`local_radar_card`、`local_radar_trend`、`local_source_item` 与 `local_source_registry`，仅用于 staging vertical slice。
- 后端通过 `psql` CLI 访问数据库，不把密码、URL 或云凭据写入仓库。
- 前端只读取 public snapshot，不读取个人记忆；页面明确显示 snapshot、watermark、rights epoch 和 evidence boundary。
- 采集器只保存 RSS/Atom 元数据、短摘要和原文链接；每个来源配置 `rights_scope` 与摘要长度上限，不把全文复制到本地产品。
- 趋势分析只使用有发布时间的真实采集条目，比较 48 小时观察窗与最近 12 小时窗口；至少 2 次提及且至少覆盖 2 个独立 `source_id` 才能进入趋势列表。输出会保留总提及、最近/前一窗口计数、增速、来源数、地区数、语言数和证据链接。单条新闻或单一来源重复发布不会被提升为趋势。
- `local_source_registry` 记录每个来源的地区、语言、启用状态、最近采集数和最近错误；因此某个来源返回 0 条或暂时超时不会被隐藏。
- M5 的实时流、生产 auth/provider、CDN、真实浏览器和治理条件仍需独立环境验证。

外部条件的输入清单和执行顺序见 [production-unblock-runbook.md](production-unblock-runbook.md)。
