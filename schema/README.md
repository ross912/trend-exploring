# M1 schema slice

本目录是 M0 有条件冻结后的首批可执行工件，不是 05 号契约的替代品。

## 当前内容

- `postgres/001_m1_core.sql`：PostgreSQL 15+ 首版 DDL，覆盖 manifest 激活、内部凭据生命周期、provider response set、token use、evaluation arm、测试治理与 gate evaluation 核心对象。`provider_response_set` 在 invocation 前冻结承诺，`provider_response_set_closure` 是同主键、无第二领域身份的 terminal child；EvaluationArm 的 output→obligation→snapshot decision→result，TestCatalog→TestRun→TestResult→GateDecision，以及 gate evaluation 的 attempts→closure→selection 均由延迟闭合 trigger 做集合相等校验。
- `json/provider-response-set.schema.json`：closed provider response set 的 JSON Schema；跨数组集合相等由 Ruby semantic validator 执行。
- `object-map.json`：每张 SQL 表到 05 号 canonical object 的唯一映射；closure 等无第二身份 child 必须显式标注。
- `fixtures/provider-response-set.valid.json`：A 失败、B 成功但完整闭合的合法批次。
- `fixtures/provider-response-set.omitted-member.invalid.json`：只保存成功 B、遗漏失败 A 的 ADV-013 反例。
- `../lib/provider_response_set.rb`：response member closure 的可执行语义。
- `../test/provider_response_set_test.rb`：合法、漏成员、错误输出、未闭 continuation、完整投影 hash、畸形结构、UUID/时间和隐藏字段测试。
- `../scripts/validate_m1.rb`：DDL 必需对象、JSON Schema 和正反 fixture 的统一入口。
- `postgres/test/003_test_governance_fixtures.sql`：P0 applicability floor、catalog 漏项/排除、result applicability 和 gate pass/blocked 反例。
- `postgres/test/004_gate_evaluation_fixtures.sql`：P1 waiver approval、完整/阻断 evaluation closure、禁止挑选通过 run 洗白失败 evaluation 的反例。
- `../scripts/generate_test_catalog.rb`：从 `docs/04-acceptance-test-plan.md` 确定性编译目标 phase 的 definitions/members/hash；未接入治理签名时显式输出 `unsigned`。
- `../scripts/generate_event_registry.rb`：确定性编译 05 号契约的 29 个 event type、semantic/family/state transitions；未接入治理签名时显式输出 `unsigned`。

## 本地验证

```bash
ruby -Ilib test/provider_response_set_test.rb
ruby scripts/validate_m1.rb
ruby scripts/validate_project.rb
ruby scripts/generate_test_catalog.rb --phase M1 --gate phase-exit
jq empty schema/json/provider-response-set.schema.json schema/fixtures/*.json
```

真实 PostgreSQL 15.18 临时集群已执行 migration、catalog smoke、测试治理和 gate evaluation fixture；`validate_m1.rb` 仍只做结构存在性与语义 fixture 检查。`schema/postgres/test/002_m1_transaction_fixtures.sh` 在 disposable 数据库中执行 ADV-013、PRI-012–013、EVA-025 的事务、恢复 epoch 和并发闭合测试；`003`/`004` 覆盖测试目录与 gate evaluation 的 fail-closed 集合语义。

当前本地回归：21 个 Ruby tests、459 个 assertions 全部通过；验证器检查 36 个关键 SQL objects、23 个关键 guards，以及全部 39 张表的 canonical mapping、append-only 和 time-profile 覆盖。M1 TestCatalog 生成器输出 72 个 definitions/members，EventRegistry 生成器输出 29 个 event types；真实 PostgreSQL 迁移、catalog smoke、事务/并发、测试治理和 gate evaluation fixture 均已通过。

## 自检记录

1. Ruby/JSON：member hash 从仅 memberKey 扩展到 unit/page/shard/continuation 完整投影；畸形结构、隐藏字段、UUID 和 date-time 均 fail closed。
2. PostgreSQL DDL：数据库重算 member hash；response set closure 后禁止追加；credential predecessor、token policy/scope/epoch 和 append-only 约束已补齐。
3. 跨工件：expected universe 改为同一 ProviderResponseSet identity 的 pre-invocation 主表与同主键 closure child；移除未登记的 Plan/Epoch 领域身份，README/07 与当前 M1 状态同步。
4. JSON 对抗：拒绝 duplicate keys、跨类型 GlobalIdentity 碰撞，并用 128-member universe 验证任一漏项都会 blocked。
5. SQL catalog：33/33 表均有 append-only guard、canonical object map 和对应 time-profile 强制字段。
6. 端到端回归：合法 fixture 通过、漏成员 fixture 失败；M0 的 233 个测试 ID、169 records、36 manifests 和 6 个 JSON 示例保持一致。
7. M0/M1 综合回归：统一验证文档状态、Markdown/JSON、验收 ID、canonical archetype/time-profile、object map 与 JSON Schema/Ruby 键集合；response set 闭合和追加路径在同一父行串行化，消除并发晚追加窗口。

## 下一实现切片

1. 为生成的 catalog/registry 接入治理签名、数据库导入和 manifest 生成流程。
2. 继续实现 EventBase/EventCausalParent SQL、权限矩阵、双时间查询模板和 identifier linter。
