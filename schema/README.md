# M1 schema slice

本目录是 M0 有条件冻结后的首批可执行工件，不是 05 号契约的替代品。

## 当前内容

- `postgres/001_m1_core.sql`：PostgreSQL 15+ 首版 DDL，覆盖 manifest 激活、内部凭据生命周期、provider response set、token use、evaluation arm、测试治理与 gate evaluation 核心对象。`provider_response_set` 在 invocation 前冻结承诺，`provider_response_set_closure` 是同主键、无第二领域身份的 terminal child；EvaluationArm 的 output→obligation→snapshot decision→result，TestCatalog→TestRun→TestResult→GateDecision，以及 gate evaluation 的 attempts→closure→selection 均由延迟闭合 trigger 做集合相等校验。
- `postgres/002_event_base.sql`：EventBase/EventTransitionState/EventCausalParent 基础设施，包含 typed GlobalIdentityRegistry、不可变 EventType registry header/definition/state/transition/API-alias children、exclusive revision CAS、注册 transition child、同域 sequence、跨域 queue proof、可用时间与 DAG/cycle guard；九张基础设施表均有 append-only guard。
- `postgres/003_manifest_import.sql`：只接受外部已验证签名的 TestCatalog/EventRegistry import 函数；unsigned、未导入 governance policy 和重复 registry/catalog version 均 fail closed。
- `postgres/004_m1_source_archive.sql`：M1 来源/权限/档案垂直切片，覆盖 collection opportunity 分母、publisher owner/dependency、RawItemVersion、PurposeAuthorization、四类 RawArtifact、blob binding、restore/format migration 与 language-evaluation manifest。
- `postgres/007_m1_coverage_item.sql`：Coverage policy/role registry、CoverageItem 与 candidate-generation unit 的 canonical projection key、UUIDv5 身份重算、typed input、并发唯一性、WatermarkGap exactly-one closure 和 append-only guard；配套 map 与 018/019 夹具单独在干净 PostgreSQL 集群回归。
- `postgres/008_m1_presentation.sql`：ClaimGenerationUnit、PresentationRenderPlan/ContentUnit 与 kind-specific child、SourceTextRef XOR 的 typed presentation slice；配套 map 与 020 fixture 在同一干净集群回归。
- `postgres/009_m1_snapshot_membership.sql`：SnapshotMembershipProfile/Role、snapshot header activation/as-of binding、unit/decision/selected-member 四方闭合；配套 map 与 021 fixture 在同一干净集群回归。
- `postgres/010_m1_data_domain.sql`：global service-principal allowlist/session gate、PersonalScope/PrivateQueryContext RLS、短期 neutral-query 执行记录与 PublicOnlyInputSnapshot/member 的 global-only、zero-private-lineage 门禁；配套 map 与 022 fixture 在干净集群回归。真实数据库角色/认证系统到 session binding 的外部接入仍需后续完成。
- `../lib/canonical_schema_compiler.rb` / `../scripts/generate_canonical_schema.rb`：从 05 registry 与 object-map 确定性编译 247 个 canonical objects，输出 schema hash 与 metadata DDL；collision/orphan/profile 负向测试见 `test/canonical_schema_compiler_test.rb`。这仍是 registry/metadata 编译边界，不替代全部领域表 DDL。
- `../lib/manifest_compiler.rb` / `../scripts/compile_manifest.rb`：统一 manifest envelope、类型白名单、关键字段、canonical payload hash 和 unsigned-before-activation 标记；`test/manifest_compiler_test.rb` 覆盖未知类型、字段缺失和签名缺失。未覆盖的全部领域 manifest 语义仍保留为 partial。
- `json/provider-response-set.schema.json`：closed provider response set 的 JSON Schema；跨数组集合相等由 Ruby semantic validator 执行。
- `object-map.json`：每张 SQL 表到 05 号 canonical object 的唯一映射；closure 等无第二身份 child 必须显式标注。
- `event-infrastructure-map.json`：002 migration 的九张基础设施表映射；它们不重复登记领域对象。
- `m1-source-map.json`：004 migration 的 15 张 M1 来源/档案表映射。
- `m1-coverage-map.json`：007 migration 的 2 张 CoverageItem 身份切片表映射。
- `m1-presentation-map.json`：008 migration 的 8 张 typed presentation 切片表映射。
- `m1-snapshot-map.json`：009 migration 的 6 张 snapshot membership 切片表映射。
- `m1-data-domain-map.json`：010 migration 的 5 张个人/全局数据域表映射。
- `m1-phase-exit-coverage.json`：M1 phase-exit 30 个 required IDs 的证据覆盖矩阵；partial/not_implemented 自动保持 gate blocked。
- `fixtures/provider-response-set.valid.json`：A 失败、B 成功但完整闭合的合法批次。
- `fixtures/provider-response-set.omitted-member.invalid.json`：只保存成功 B、遗漏失败 A 的 ADV-013 反例。
- `../lib/provider_response_set.rb`：response member closure 的可执行语义。
- `../test/provider_response_set_test.rb`：合法、漏成员、错误输出、未闭 continuation、完整投影 hash、畸形结构、UUID/时间和隐藏字段测试。
- `../scripts/validate_m1.rb`：DDL 必需对象、JSON Schema 和正反 fixture 的统一入口。
- `postgres/test/003_test_governance_fixtures.sql`：P0 applicability floor、catalog 漏项/排除、result applicability 和 gate pass/blocked 反例。
- `postgres/test/004_gate_evaluation_fixtures.sql`：P1 waiver approval、完整/阻断 evaluation closure、禁止挑选通过 run 洗白失败 evaluation 的反例。
- `postgres/test/005_event_base_fixtures.sql` / `006_event_base_smoke.sql`：EventBase registry/aggregate/revision 与 EventCausalParent 时间、sequence、queue proof、DAG/cycle 反例；`023_event_family_expected_head_fixtures.sql` 进一步覆盖 RADAR_PUBLICATION/REVOCATION_EPOCH 的签名 registry、revision-1 predecessor 与 expected-head 反例。
- `postgres/test/007_manifest_import_fixtures.sql`：签名验证、治理 policy 依赖、重复 registry/catalog 和 unsigned import 反例。
- `postgres/test/008_m1_source_archive_fixtures.sql` / `009_m1_source_smoke.sql`：M1 来源/权限/档案 phase-exit 垂直切片正反例与 59 表 append-only smoke。
- `postgres/test/011_manifest_activation_fixtures.sql`：ManifestActivationDecision expected-head CAS、predecessor 与 authoritative range exclusion 反例。
- `postgres/test/013_manifest_activation_concurrency.sh`：双进程同 series/revision 竞争，验证 row lock + expected-head CAS 只有一个 winner。
- `postgres/test/018_coverage_item_fixtures.sql` / `019_coverage_item_concurrency.sh`：CoverageItem canonical UUIDv5、projection-key 唯一、generation unit、append-only 与双进程并发反例。
- `postgres/005_m1_gate_report.sql` / `postgres/test/010_m1_gate_report_fixtures.sql`：数据库直接按 catalog/run/result 计算 M1 phase-exit report，缺结果和非 pass 结果 fail closed。
- `postgres/006_governance_quorum.sql` / `governance-quorum-map.json` / `postgres/test/012_governance_quorum_smoke.sql` / `postgres/test/024_test_governance_signature_fixtures.sql`：ApprovalDecision signer/key quorum、manifest kind allowlist、active/expiry/revocation 校验和 append-only child；导入仍要求 ingress 已完成密码学 detached-signature 验证。
- `../scripts/generate_test_catalog.rb`：从 `docs/04-acceptance-test-plan.md` 确定性编译目标 phase 的 definitions/members/hash；未接入治理签名时显式输出 `unsigned`。
- `../scripts/generate_event_registry.rb`：确定性编译 05 号契约的 29 个 event type、semantic/family/state transitions；未接入治理签名时显式输出 `unsigned`。
- `../scripts/generate_permission_matrix.rb`：确定性生成 8 个用途集合的 deny-by-default 权限矩阵；推理、训练、展示和 prevalence 不共享隐式授权。
- `../scripts/generate_bitemporal_queries.rb`：生成 event、operational、derived、bitemporal version 的 as-known 查询模板。
- `../scripts/lint_identifiers.rb`：跨文档验收 ID、object map、event infrastructure map 和 EventRegistry 的一致性 lint。
- `../scripts/evaluate_m1_gate.rb`：按 `introduced_phase`/applicable/blocking=phase-exit 计算 M1 gate；未签名 catalog、缺 result、not_applicable 和失败结果均阻断。
- `../scripts/report_m1_readiness.rb`：对 M0→M1 inherited phase-exit 项逐项对账证据，避免把局部 fixture 误报成 M1 ready；canonical_contract mutation tests 覆盖 archetype/time-profile 缺项和重项。

## 本地验证

```bash
ruby -Ilib test/provider_response_set_test.rb
ruby scripts/validate_m1.rb
ruby scripts/validate_project.rb
ruby scripts/generate_test_catalog.rb --phase M1 --gate phase-exit
ruby scripts/generate_event_registry.rb
ruby scripts/generate_permission_matrix.rb
ruby scripts/generate_bitemporal_queries.rb
ruby scripts/lint_identifiers.rb
ruby scripts/evaluate_m1_gate.rb --catalog /path/to/signed-m1-catalog.json
jq empty schema/json/provider-response-set.schema.json schema/fixtures/*.json
```

真实 PostgreSQL 15.18 临时集群已执行 migration、catalog smoke、测试治理和 gate evaluation fixture；`validate_m1.rb` 仍只做结构存在性与语义 fixture 检查。`schema/postgres/test/002_m1_transaction_fixtures.sh` 在 disposable 数据库中执行 ADV-013、PRI-012–013、EVA-025 的事务、恢复 epoch 和并发闭合测试；`003`/`004` 覆盖测试目录与 gate evaluation 的 fail-closed 集合语义。

当前本地回归：Ruby 全量测试、M0+M1 validator、identifier linter、生成器、M1 gate evaluator 和 readiness report 均已接入；001 的 39 张领域表、002 的 9 张 EventBase/registry 基础设施表、004 的 15 张来源/档案表、006 的 2 张 governance quorum 表（总计 65 张基础表，另含 vertical slices）均在 PostgreSQL 15.18 临时集群通过 fixture/smoke；007 的 2 张 CoverageItem、008 的 8 张 typed presentation、009 的 6 张 snapshot membership、010 的 6 张 data-domain 表另在干净 PostgreSQL 15.18 集群通过 018–022 fixture/concurrency。M1 TestCatalog 生成器输出 72 个 definitions/members，EventRegistry 生成器输出 29 个 event types；unsigned catalog 被 gate evaluator 明确阻断，CTR-010 的越界 result/append-only 负向夹具、CTR-011 的 M2/M5 inherited catalog 回归、LAN-001 的十种正式语言评测闭合回归、CTR-007 的修订强度单调性与签名密钥生命周期回归、CTR-006 的静态、身份 allowlist 与数据库 data-domain 回归已通过；CTR-006 的真实数据库角色/认证 session binding、CTR-007 的 oracle/fixture 强度语义、CTR-014 的跨 event typed claim/citation/complete snapshot closure、CTR-015 的真实 policy/role FK 与 watermark-gap 闭合、CTR-018/020 的真实 SourceRegistry universe/selected typed-member 投影仍未实现，当前 readiness 为 21/30 fixture_passed、9/30 blocked。

## 自检记录

1. Ruby/JSON：member hash 从仅 memberKey 扩展到 unit/page/shard/continuation 完整投影；畸形结构、隐藏字段、UUID 和 date-time 均 fail closed。
2. PostgreSQL DDL：数据库重算 member hash；response set closure 后禁止追加；credential predecessor、token policy/scope/epoch 和 append-only 约束已补齐。
3. 跨工件：expected universe 改为同一 ProviderResponseSet identity 的 pre-invocation 主表与同主键 closure child；移除未登记的 Plan/Epoch 领域身份，README/07 与当前 M1 状态同步。
4. JSON 对抗：拒绝 duplicate keys、跨类型 GlobalIdentity 碰撞，并用 128-member universe 验证任一漏项都会 blocked。
5. SQL catalog：001 的 39/39 领域表与 002 的 5/5 EventBase 基础设施表均有 append-only guard；领域表由 object-map 映射，基础设施表由 event-infrastructure-map 映射。
6. 端到端回归：合法 fixture 通过、漏成员 fixture 失败；M0 的 233 个测试 ID、169 records、36 manifests 和 6 个 JSON 示例保持一致。
7. M0/M1 综合回归：统一验证文档状态、Markdown/JSON、验收 ID、canonical archetype/time-profile、object map 与 JSON Schema/Ruby 键集合；response set 闭合和追加路径在同一父行串行化，消除并发晚追加窗口。

## 下一实现切片

1. 为生成的 catalog/registry 接入治理签名、数据库导入和 manifest 生成流程。
2. 将权限矩阵与 RevocationDependencySnapshot、egress/训练执行器接通。
3. 为 bitemporal query 模板补充投影表和时间旅行集成 fixture。
4. 用真实 signed catalog、M1 test results 和 gate decision 完成 phase-exit 评估。
