# 多来源信息台

当前阶段：单用户本地产品已经可持续运行（PostgreSQL 15.18 + Ruby API + 统一前端 + macOS 定时任务），接入 13 个编辑 RSS、6 个预设 Google News 主题查询入口和 8 个 Google News locale headlines 入口；signal 分析仍只接收当前支持的中英文，locale 探索会保留更多原文语言供归档/浏览。它记录域名观察、重复词频候选和高精度低召回事件文本相似候选；事件地域尚未验证，主题查询受预设关键词条件约束，词频与事件候选输出只是可追溯线索，机器译文不等于人工核验。它不是全球覆盖、开放世界发现或连续实时流。

这个项目把公开来源的采集入口、元数据、短摘要和原文链接保存在本地，并以去重来源标识统计哪些词在重复出现；它不把入口标签当作事件地域，也不把域名观察当作组织属性。当前能力用于可追溯的本地核验，不承诺穷尽世界或预测变化。

探索前沿是独立的 locale-conditioned、topic-unconditioned 聚合器中介切片：每批从配置的 Google News locale headlines 入口记录成功/空/失败分母，并按不可变版本选择最多 12 条归档材料。它只支持原文归档与浏览，不进入趋势、事件候选、卡片或翻译；locale-only 发布会在 snapshot 标记 `reused_previous` 并沿用 signal projection，不声称重要、新颖、趋势或早期信号；事件地域仍未验证。

本地日报账本另有两个 Asia/Shanghai 半开时段（08:00 morning、19:00 evening），先发布不可变 raw listings，再可选地通过 CLI 追加可替换、可追溯的 AI summary projection；summary 不回写 edition/placement/version，不代表全球覆盖或确定性结论。无 API 凭据会明确保留 blocked run，raw 日报仍可读。

运维入口见 [本地产品运行手册](docs/local-product.md)：默认持久化在 macOS 的 `~/Library/Application Support/TrendExploring`，无 PostgreSQL 时安装器会校验固定源码 SHA256 后构建；LaunchAgent 提供 07:55/18:55 预采集、08:05/19:05 日报周期和登录后本地 UI server。`status_local.rb`、`backup_local.sh`、`restore_local.sh` 分别提供状态、全局+个人一致性备份和 disposable DB 恢复验证。

## 阅读顺序

1. [需求基线与实施路线](docs/00-requirements-and-implementation-roadmap.md)
2. [全球信息覆盖矩阵](docs/01-global-information-coverage-matrix.md)
3. [弱信号定义与评分规范](docs/02-weak-signal-specification.md)
4. [设计审查与收敛记录](docs/03-design-review-log.md)
5. [规范验收测试计划](docs/04-acceptance-test-plan.md)
6. [统一数据、时间与决策契约](docs/05-canonical-data-and-time-contract.md)
7. [Codex × Kimi 中继协作协议](docs/06-kimi-codex-relay-collaboration-protocol.md)（外部协作附录，非知识库规范本体）
8. [设计续跑交接](docs/07-continuation-handoff.md)
9. [外部开源项目参考目录](reference/README.md)
10. [本地产品 vertical slice](docs/local-product.md)

## 当前架构不变量

- 全球基础雷达不读取用户记忆、点击或个人兴趣；
- 当前问题先在个人域去标识；个人记忆只在记忆盲证据检索完成后参与对话解释；
- 原始资料、派生分析和个人认知分层保存；
- AI 分析和信号状态只追加新版本；未知闭合时间由 Supersession/StateEvent 投影，不回写旧结论；
- 热点规模与认知探索分开计算和展示；
- 信号使用分项向量与分通道判定，不使用神秘总分；
- 所有事实和判断均可追溯到具体原始版本；
- 事实/来源主张使用证据蕴含门禁，AI 推断使用前提支持、反证与替代解释门禁；
- 候选与 proposition family 双身份冻结，合并/拆分不改变前瞻评价分母；
- 数据缺失、来源断流和不可观察区域必须显式呈现。

## 契约与回归入口

仓库同时保留从统一契约派生的 PostgreSQL DDL、JSON Schema、schema validator、反例 fixtures 与 M1 端到端切片；这些工件用于验证 identity/record registry、manifest activation、provider response set、token use、credential lifecycle 与 evaluation arm closure，不等同于本地产品的运行状态。

首批 M1 工件已建立：

- [PostgreSQL 核心 DDL](schema/postgres/001_m1_core.sql)
- [Provider response set JSON Schema](schema/json/provider-response-set.schema.json)
- [可执行闭合逻辑](lib/provider_response_set.rb)
- [M1 测试与运行说明](schema/README.md)

M0 与 M1 的统一静态回归入口：

```bash
ruby scripts/validate_project.rb
```

低配 Ubuntu 云服务器的 PostgreSQL 验证说明见 [云端验证入口](scripts/cloud/README.md)。
