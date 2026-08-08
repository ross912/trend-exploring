# 个人全球信息知识库

当前阶段：M5——本地 staging vertical slice 已可启动（PostgreSQL 15.18 + Ruby API + Radar 前端），并已接入可验证的中文 RSS/Atom 来源采集；M0–M4 阶段门已有可信 evidence，M5 的 10 个生产 release gate 仍需实时/生产环境验证。当前验收目录包含 233 个可失败场景。旧“连续无新增”计数停在 0/3，不再继续无限审查；后续问题进入 implementation backlog，重大数据破坏、越权或错误能力声明除外。

这个项目不承诺穷尽世界、消除所有偏差或预测黑天鹅。它的目标是在公开声明的可观察范围内，以不受个人兴趣驱动、权重透明、原始证据可追溯的方式扩大信息覆盖，并尽早识别可能正在发生的变化。

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

## 当前实施入口

从统一契约派生首批 PostgreSQL DDL 与 JSON Schema，并建立 schema validator、最小反例 fixtures 和 M1 小规模端到端垂直切片；先覆盖 identity/record registry、manifest activation、provider response set、token use、credential lifecycle 与 evaluation arm closure，再做来源授权、语言质量、处理成本和报告时延试验。

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
