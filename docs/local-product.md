# Local product vertical slice

当前仓库已经有一个可持续运行的单用户本地产品：PostgreSQL 15.18 数据库、Ruby WEBrick API、统一前端、定时采集/日报周期、备份与恢复验证。它仍不是多用户、云端高可用或开放互联网服务。

## 启动

### DeepSeek V4 Pro

翻译、日报总结和资料对话共享 `deepseek-v4-pro`，默认 Base URL 为 `https://api.deepseek.com`。不要把密钥写进仓库或命令历史；在交互终端运行：

```bash
bash scripts/local/configure_deepseek.sh
```

脚本会把密钥写入 `~/Library/Application Support/TrendExploring/secrets/deepseek_api_key`，目录权限 `700`、文件权限 `600`。LaunchAgent 运行副本不包含 secrets，客户端直接读取该文件；备份脚本只导出数据库，不复制 secrets。也可在一次性进程里使用 `DEEPSEEK_API_KEY`。没有凭据时采集继续运行，正文/元数据翻译进入 `credential_blocked`，日报 summary 保留 blocked，对话返回原始 evidence 而不生成答案。

`run_product.sh` 会在用户持久目录创建并启动本地 PostgreSQL 15 instance。macOS 默认目录是 `~/Library/Application Support/TrendExploring`，数据库、Unix socket、运行时和备份都在该目录下，默认端口为 `55433`。脚本随后执行非破坏性 schema migration 并启动 API。启动不会清空已有 archive、snapshot、日报或分析结果。只有显式设置 `LOCAL_RESET_DEMO=1` 才允许重置默认本地库；`LOCAL_SEED_DEMO=1` 只会在没有 snapshot 时写入演示 snapshot。也可以手动运行 `scripts/local/start_postgres.sh`，或用 `LOCAL_STATE_DIR`、`PG_BIN`、`LOCAL_PSQL`、`LOCAL_PGHOST`、`LOCAL_PGPORT`、`LOCAL_PGDATABASE`、`LOCAL_PGUSER` 覆盖运行位置和连接参数。

默认启动会从 `config/sources.json` 做一次手动/启动时的 RSS/Atom 批采集；在发布新的批次 snapshot 前，先按限额处理非中文元数据译文，使当批卡片可以直接读取已完成的中文投影。原语言 title/summary 与不可变版本始终保留，翻译失败只标记待翻译/失败，不伪装成中文。它不是持续连接的实时流；signal watermark 只由本批 `signal_eligible` 条目的采集时间推进，locale-only 批次沿用前序 watermark，并在 snapshot 标记 `reused_previous`；探索前沿另有独立 batch attempts 与成功/空/失败分母。当前配置有 13 个编辑 RSS、6 个预设主题查询和 8 个 Google News locale headlines 入口；locale 入口的每批成功有条目/成功为空/失败都计入分母。locale 探索前沿是 topic-unconditioned、aggregator-mediated、exploration-only 的归档/浏览切片；非中文元数据进入同一版本绑定翻译队列，但这些材料不进入趋势、事件候选或 signal 卡片。市场标签不是事件地域，事件地域状态明确为未验证。这里不声称全球覆盖、开放世界发现或独立媒体组织覆盖；机器译文明确标注且不代表人工核验。若当前网络不可用，可使用 `LOCAL_INGEST_LIVE=0 bash scripts/local/run_product.sh` 只启动已有本地数据。

混合 signal+locale 批次先提交一个 `fresh_batch` signal snapshot，再以相同 watermark/method/rights 及重键后的 signal surface 提交下一 revision 的 `reused_previous` exploration snapshot；locale batch 没有 selection 时只关闭 attempts，不额外制造空 membership revision。

```bash
ruby scripts/local/bootstrap_radar.rb
ruby scripts/local/start_radar.rb
```

本地日报事实账本只记录 08:00 morning（前一日 19:00–当日 08:00）和 19:00 evening（当日 08:00–19:00）两个半开窗口，时区固定 `Asia/Shanghai`、数据库用 UTC。先为覆盖 archive `created_at` 的完整日期范围生成 slots，再用显式的 processing/selection frontier 和 comparison watermark 发布；缺少 nominal slot 或 cutoff 落后超过 60 分钟会 fail closed。入口是：

```bash
ruby scripts/local/generate_report_slots.rb --from 2026-08-09 --to 2026-08-10
ruby scripts/local/publish_report_edition.rb --slot-id report-morning-20260810 \
  --processing-frontier 2026-08-10T08:00:00+08:00 \
  --selection-frontier 2026-08-10T08:00:00+08:00 \
  --comparison-watermark 2026-08-10T08:00:00+08:00
```

`GET /api/reports/latest?kind=morning|evening` 只读已发布 edition 的 raw listings，并 additive 返回 `summary` 投影。summary 由独立 CLI 生成：新 artifact 的每个单元都是带 `kind`、`epistemic_status`、`claim_id`、field-level `evidence_scopes` 与 relation 的 typed claim，并以 `claim_gate_status=verified` 标记；历史两字段 artifact 显示 `legacy_unverified`，不在 UI 中冒充证据。provider exchange receipt 与 summary run 绑定。无凭据时保留 `blocked` run，provider/JSON/claim gate 校验失败时保留 `failed` run；summary 失败绝不影响 raw report HTTP 200。0 item edition 明确为 `blocked`（not applicable），不调用模型。

只允许通过 CLI 生成 summary，不提供公开 POST 路由：

```bash
ruby scripts/local/generate_report_summary.rb --edition-id edition-... --idempotency-key summary-...
# 或按日报种类选择当前 latest edition
ruby scripts/local/generate_report_summary.rb --kind morning
```

也可以直接运行：

```bash
bash scripts/local/run_product.sh
```

然后打开 <http://127.0.0.1:3000>。API 入口：

- `GET /api/health`：数据库与 PostgreSQL 版本
- `GET /api/radar`：当前 published snapshot、分离的 `trends`、`event_candidates`、`cards` 新闻、`sources` 来源矩阵、`coverage` 覆盖边界，以及 additive 的 `exploration.latest_batch/items/boundary`；探索条目回查 immutable version/capture，只呈现 `raw_listing`。快照还显式标记 `signal_projection_status`：`fresh_batch` 为本批 signal 投影，`reused_previous` 会给出 `signal_source_snapshot_id`，说明 locale-only 探索发布没有冒充新的 signal 分析。
- `GET /api/reports/latest?kind=morning|evening`：日报事实账本 latest edition 或 `scheduled`/`not_run`/`failed`；内容为 raw listings，并在存在时附加可追溯 summary。没有 provider 凭据时明确为 blocked/not generated。
- `POST /api/radar/publish`：默认关闭并返回 403；只在本机显式设置 `LOCAL_ENABLE_PUBLISH_API=1` 后开放完整 snapshot + cards + trends 原子发布入口。可选传入 `event_candidates` 和已冻结 batch 的 exploration membership，服务端会回查 version/capture/source contract/attempt。
- `GET /api/weak-signals`：返回最新弱信号规则运行；基线不足时保留 `warming_up`，不伪造候选。
- `GET /api/world-changes`：返回固定 `run_id/as_of` 的五通道世界变化候选；逐通道公开有界 lineage refs（资格/support/反证最多 3/2/2 条，仅含 `version_id/title/source_url/publisher/channel/role`），并通过 `truncated/evidence_boundary` 明示正文不出接口；内部追加式账本仍保留完整证据。响应标记 `not_a_prediction=true`。
- `GET /api/signals/lifecycle`：只读 operational lifecycle state/trigger/evidence；`retrospective_reanalysis` 单列，不能冒充当时发现。
- `GET /api/multilingual-concepts`：只读 provider-backed 多语言概念参与候选，并返回 `run`、`status`、`examined_count` 与 `denominator`；`not_run` 表示任务尚未运行，不把空候选解释为无变化，也不伪造 `translation_equivalent`。定时周期默认以 `dry_run`/无 provider/不持久化接入概念映射；付费生产调用必须显式开启。
- `POST /api/conversation/query`：只接受 JSON；先做敏感信息阻断，再只读检索全局 archive 与物理隔离的个人记忆。返回 server-owned `thread_id`、`turn_id` 与 evidence snapshot id；没有 provider 凭据时返回 evidence/memory 而不伪造回答。
- `GET /api/conversation/replay/:turn_id`（或 `?turn_id=`）：严格 ID、只读、无 body、owner 由服务端固定；只回放不可变 personal ledger，不重新检索 archive 或调用 provider。

服务启动后可用另一终端运行 HTTP smoke：

```bash
ruby scripts/local/smoke_radar.rb
```

持续运行的最小运维闭环是：07:55/18:55 预采集，08:05/19:05 生成对应日报、运行弱信号、世界变化候选、默认 dry/no-paid concept mapping 与 summary；世界变化使用独立固定 run id，失败只降级该面板，不影响 raw 日报。若 macOS 休眠或 launchd 延迟，周期会在下一个日报边界前补发当前仍为 `scheduled` 的时段。截止时间仍固定为 08:00/19:00，不会提前发布或把补发时刻后的材料混入旧时段；重复执行使用固定幂等键，只产生一个 edition。周期可用 `--now` 做时钟测试。它是定时批处理，不是连续实时流。采集失败会发布 `degraded/DEGRADED_COVERAGE` 日报，不覆盖旧 published head。macOS 可用 `bash scripts/local/install_launch_agent.sh` 安装幂等的采集、周期和本地 UI server LaunchAgents，`uninstall_launch_agent.sh` 卸载；周期 wrapper 会先启动 PostgreSQL、迁移全局/个人库，再执行周期。

运行状态：`ruby scripts/local/status_local.rb` 输出 server、global/personal DB、迁移、latest ingest、日报槽位和 weak-signal 状态 JSON。备份：`bash scripts/local/backup_local.sh [目录]` 同时导出全局和个人库并写 manifest/count/hash；恢复只创建带时间戳的 disposable DB，`LOCAL_RESTORE_CLEANUP=1` 可在验证后清理，绝不覆盖运行库。

## 本地切片边界

- PostgreSQL 表为 `local_radar_*`、`local_source_*` 以及 `local_report_schedule_slot`、`local_report_publication_attempt`、`local_reportable_arrival`、`local_report_edition`、`local_report_item_placement`，仅用于 staging vertical slice。
- 后端通过 `psql` CLI 访问数据库，不把密码、URL 或云凭据写入仓库。
- 前端只读取 public snapshot，不读取个人记忆；页面明确显示 snapshot、watermark、rights epoch 和 evidence boundary。
- 采集器只保存 RSS/Atom 元数据、短摘要和原文链接；每个来源配置 `rights_scope` 与摘要长度上限，不把全文复制到本地产品。`metadata_only` capture 只保存 feed 的请求/响应元数据与 body hash，不是正文原件，也不能从本地存储还原 feed body 或全文。
- `rights_scope` 采用 `full_archive` / `excerpt_only` / `link_only`。`full_archive` 还必须提供 `archive_permission_basis`（出版方许可、开放许可、公版或已审核 robots/条款）及 `archive_permission_verified_at`；否则抓取器在网络请求前拒绝。它不绕过登录、付费墙、验证码、JavaScript gate 或访问拒绝。当前配置全部是 `excerpt_only`，因此新表和流水线已经具备，但不会擅自抓取这些站点正文。
- 合法归档的正文按具体 `source_version_id` 追加保存，包含原始正文、图注、提取器版本、最终 URL 和正文哈希；中文译文在独立 artifact 中保存，记录 DeepSeek 模型、提示版本、用量和原文正文哈希，永不覆盖原文。默认每次正文归档20条、全文翻译5条，每日最多20万输入字符，失败最多自动尝试3次；可用 `LOCAL_ARTICLE_ARCHIVE_LIMIT`、`LOCAL_FULLTEXT_TRANSLATION_LIMIT`、`LOCAL_DEEPSEEK_DAILY_CHARACTER_LIMIT` 调整。
- 只有 HTTP 成功且解析出有效条目的 feed 响应才追加 capture 与其实际写入的 item versions；失败或空响应不会推进 signal watermark，但会在来源矩阵与 locale batch attempts 中保留状态。同一 capture 重放幂等，不同 capture 即使内容相同也会保留观察历史。
- `local_source_capture` 与 `local_source_item_version` 由 PostgreSQL 触发器强制 append-only（禁止 UPDATE/DELETE/TRUNCATE）；`local_source_item` 仍是可由采集器刷新的 current projection，但 DELETE/TRUNCATE 被阻断，且 item→version 外键为 `ON DELETE RESTRICT`，不会级联抹掉历史。017 迁移对缺失或歧义的旧 FK fail closed；合规删除/撤销事件尚未实现，不能把“不可删除”误读为已完成法律删除义务。
- 编辑 RSS 使用配置中的稳定出版方身份；同一出版方的多个 feed 共享一个 `publisher_id`。Google News 入口是带 `query_conditioned=true` 的主题查询，只从条目 `<source url>` 观察规范化域名；缺失或非法 URL 保留为 unresolved，不按名称猜组织。
- 趋势分析只使用有发布时间的真实采集条目，比较 48 小时观察窗与最近 12 小时窗口；至少 2 次提及且至少覆盖 2 个去重来源标识（配置出版方或观察域名）才能进入趋势列表。输出中的 `regions` 是入口标签，不是事件地域；趋势是非事件聚类的词频线索，不代表世界变化结论。单条新闻或单一来源重复发布不会被提升为趋势。
- 事件候选是新增的高精度、低召回前置层：只读启用 registry 中条目的原始 title/summary，要求发布时间、已解析 `publisher_id`、同语言、36 小时内和确定性锚点相似；使用规则实体样式（数字/单位、英文连续 trigram、多词大写名称、中文长 shingle/引号短语），不是 NER、模型、embedding 或翻译。`publisher_id` 只用于去重与资格，不证明组织独立。至少两个不同且已解析的非 query 出版方才有资格；query evidence 可附加但不计资格；不跨语言，不判断事件重要性、新颖性、影响或弱信号，候选不会跨 snapshot 延续生命周期。
- `shared_anchors` 只报告覆盖全部 qualifying 出版方的共同锚点，并带 `supporting_qualifying_source_count`；两两边上的不同锚点不会被冒充成全体共同事实，全体交集可以为空，不额外抬高 complete-link 两两门槛。解释会明确每一对通过门槛及 query evidence 不计资格。
- 本批不持久化 `pairwise_anchors`；逐对门槛可由原始 `evidence_items` 与 `matching_method` 离线重算。
- 每条候选证据保留 `version_id`、`capture_id`、`content_hash` 以及 source name/language/region、publisher name/url/id/identity、source kind 和 query-conditioned 等捕获时身份字段；发布时会在同一事务中回查不可变 archive version，逐字段核对这些值、标题、摘要、链接、发布时间与 query 条件。旧表迁移行的资格元数据只在迁移时从当时的 current projection + registry 回填，并标记 `migration_current_projection`；新采集在 capture-time 冻结并标记 `capture_time`，之后不随 registry/current projection 改写。`registry.enabled` 只作为 publish-time 策略门禁，不是历史身份来源。JSON 证据仍不是 JSON FK，缺失、错绑、伪 publisher/query、错误 capture/version/hash 或禁用来源会让整批发布回滚。
- `local_source_registry` 记录每个入口的编辑范围/查询目标标签、语言、启用状态、最近采集数和最近错误；`coverage` 分开展示编辑 RSS、主题查询 feed、配置出版方、观察出版方域名、内容语言、unresolved 条目及覆盖债务。查询条件与事件地域未验证是当前边界，不是全球覆盖结论。
- `schema/postgres/012_breadth_discovery.sql` 增加 immutable discovery basis/policy/locale fields、`local_collection_batch`、materialized planned source set、每源 fetch attempt 和 snapshot-bound `local_radar_exploration_item` membership。`locale_headlines` 必须无 q/query/search 参数、`query_topics=[]`，selection 最多 12 条、每 publisher 1 条、每 locale 2 条；unresolved 不猜出版方。
- 连续实时流、多用户认证、云端高可用/CDN、正式 provider 凭据、全文授权采集与开放世界覆盖仍不在当前本地产品范围内。

外部条件的输入清单和执行顺序见 [production-unblock-runbook.md](production-unblock-runbook.md)。
