# 规范验收测试计划

- 版本：v0.2-m0-baseline
- 日期：2026-08-05
- 状态：M0 有条件冻结的可执行验收基线；M1 继续物化测试

## 1. 目的

本计划把“覆盖广、新颖、能发现早期变化”拆成能够失败的测试。著名成功案例的故事性回放不构成产品有效性证据。

任何能力声明必须同时给出分母、比较基线、时间截止、失败阈值和全量失败记录。缺少任一项的“命中案例”只能用于说明，不能用于验收。

## 2. 测试元数据与阻断语义

测试定义与执行事实必须分开保存。`TestDefinitionVersion` 只描述“要测试什么、何时适用、什么结果算失败”，不得承载某次运行的 `actual/result/artifacts`：

| 字段 | 允许值与含义 |
|---|---|
| test_id / test_definition_version_id | 稳定测试身份与不可变定义版本；目录和执行结果必须引用具体定义版本，不能只引用可漂移的 test_id |
| phase | 测试首次引入阶段（等同 `introduced_phase`）：M0 契约、M1 原始档案、M2 日报、M3 弱信号、M4 个人记忆、M5 实时雷达 |
| run_on_or_after | 默认从 introduced phase 起所有后续阶段均运行；只有机器可判定的 applicability predicate 可返回 not-applicable |
| applicability_predicate | 基于组件、数据用途和变更影响面的确定性表达式，不能由实现者临时勾选 |
| waiver_policy | 只声明该定义是否可豁免；仅非不变量测试可为 true，P0 架构/安全/隐私不变量不可豁免；具体 waiver 只在 GateDecision 引用 |
| severity | P0 为架构不变量或会制造错误事实的缺陷；P1 为质量、可运维性或能力声明缺陷 |
| blocking | phase-exit、normal-edition、service-claim、release、capability-claim、version-promotion 或 none |
| fixture_contract | 允许使用的固定夹具族、最低难度/覆盖和不可缩弱约束；具体 `fixture_version` 在 TestRun 中冻结 |
| config_contract | 本测试要求冻结的来源、权限、采样、SLO、模型、阈值和排序配置；具体 `config_version` 在 TestRun 中冻结 |
| oracle_spec | 机器断言、人工金标或盲评协议的不可变规范；不得是恒真、空断言或由被测实现自行决定阈值 |
| governance_refs | `test_governance_policy_version`、签名、审批及相对前版的语义 diff/影响面 |

每次执行使用独立对象记录，不得回写 TestDefinitionVersion：

| 对象 | 必填执行字段 |
|---|---|
| `TestCatalogManifest` | `test_catalog_manifest_id`、目标 phase/gate、完整 definitions universe、全部适用 `test_definition_version_ids[]`、排除项及机器判定依据、catalog hash、生成时间、`test_governance_policy_version` 与签名 |
| `TestRun` | `test_run_id`、catalog ID、代码/环境、实际 `fixture_version/config_version`、开始/结束时间、执行主体和输入清单 |
| `TestResult` | `test_result_id`、run ID、definition version ID、`actual`、`result`（pass、fail、blocked、not_applicable）、reason codes、日志/差异/置信区间和 artifact IDs |
| `GateDecision` | `gate_decision_id`、gate type/target、catalog/run/result IDs、未通过项、`test_waiver_ids[]`、`decision`（pass 或 blocked）、决定时间及 `approval_decision_ids[]` |

blocking 的解释：

- phase-exit：从 introduced phase 起，不通过则当前及以后任何适用阶段都不能退出；
- normal-edition：从 introduced phase 起，不通过时仍可生成明确标记的降级版，但不能标为正常版；
- service-claim：不改变任何单期 edition，但持续阻止“滚动服务达到 SLO”的声明；
- release：从 introduced phase 起，不通过则当前版本及以后受影响版本不能发布；
- capability-claim：不阻止工程影子运行，但持续阻止对应产品能力声明；
- version-promotion：不通过则当前及以后受影响的 challenger 不能替换 champion；
- none：只记录，不构成硬门禁。

表格中的每一行都是独立测试。未冻结的数值必须引用一个版本化 provisional 配置；配置缺失本身即失败，不能用“基本稳定”“明显”“高质量”等无数值含义的词替代 oracle。

每行同时编译为带版本和签名的 `TestDefinitionVersion`。表格未重复展示的默认值是：P0 的 `applicability_predicate=always` 且不可改为 false；P1 从 introduced phase 起默认 always，只有测试目录中预先登记、独立审批并通过 change-impact 测试的组件谓词才可缩小。predicate 缺失、解析失败、依赖字段未知、catalog 缺项或签名不合法/无权/已撤销一律 fail closed：测试视为 applicable 且失败/blocked，不能视为 not-applicable。

`TestGovernancePolicy` 冻结信任根、签名用途、审批角色/quorum、密钥轮换与撤销、定义强度比较和变更生效边界；`SigningKeyVersion` 记录密钥用途、有效期、状态与继任链；`ApprovalDecision` 绑定旧/新定义 hash、结构化 diff、影响面、批准者及生效时间。`earliest_introduced_phase`、P0 severity、blocking floor、oracle 强度和 fixture 最低覆盖不得被新定义静默削弱。合法但无权的签名与损坏签名等价；审批晚于目标 gate 不得追认已经发生的退出或发布。任何 TestDefinitionVersion 变化保留旧版；在合法 ApprovalDecision 生效且 change-impact 门禁通过前，旧版中更强的约束继续进入 TestCatalogManifest。

## 3. 证据等级

由弱到强：

1. 单元测试：证明局部计算符合定义；
2. 合成注入：证明管道能对预设模式作出反应；
3. 历史时间点回放：证明数据截止和流程机制，但现代模型可能含未来知识；
4. 隐藏真实语料：证明对未参与调参的数据具有一定泛化能力；
5. 锁定规则后的真实前瞻影子运行：支持实际发现能力声明的主要证据。

低等级测试通过不能替代高等级证据。每项能力报告必须标明其最高证据等级。

## 4. 冻结对象、正式时间字段与原因码

### 4.1 每次运行必须冻结

- 语料与原始对象清单；
- 来源注册表及目标观测框架；
- 各处理目的的可观察集合；
- 采样政策、纳入概率和计划采集机会；
- 主题体系、模型、提示模板、特征和排序代码；
- provisional SLO 配置；
- 随机种子；
- 前瞻评估协议及其哈希。

### 4.2 正式时间语义

原始条目和版本必须区分以下正式时间：

1. event_time：事件发生时间，可未知或为区间；
2. source_published_at：来源声明的发布时间，可未知；
3. item_first_seen_at：系统首次合法观察并登记该逻辑条目的时间，必填且不可回填；
4. version_observed_at：系统首次发现该内容版本的时间，必填；
5. captured_at：本次原始快照安全写入完成时间，必填；
6. version_available_at：该版本通过许可与安全门禁、达到可读取状态的时间；被拒绝时可为空，但拒绝决定必填。

派生对象的时间字段必须由 05 第 5.1、7.2 节登记的记录原型决定，不能按名称后缀猜测：

- `bitemporal_version` 清单中的对象保存 `system_from`、`valid_from`、可选 `asserted_valid_until`、`system_available_at`、`as_of` 和 `run_mode`；权威版本行不回写 `system_to/valid_to`，查询所见的 `projected_system_to/projected_valid_to` 只由当时可见的 EventBase 投影；
- FeatureArtifact、CoverageItem、SignalCandidate、CandidateGenerationDecision、SelectionDecision、ReportClaim、AnalysisRun 与 ModelOutputArtifact 等不可变派生记录只保存 `system_available_at/as_of/run_mode/input record IDs`，不得凭 `Version` 以外的自然语言描述给它们补造闭合区间；
- standalone snapshot 保存 `snapshot_frozen_at/system_available_at/as_of` 与物化输入，不拥有虚构的稳定 snapshot parent；manifest 使用自己的配置生效时间；
- `source_updated_at` 只属于来源自报元数据，可未知，不能充当任何派生对象的系统可用时间。

时间顺序及空值规则以《统一数据、时间与决策契约》为准。任何 as-of 查询和历史回放不得读取 system_available_at 晚于截止 T 的派生对象。

`processing_watermark.frontier_at` 表示输入 `information_arrival_at` 的连续完成前沿；它不是最后任务时间或最大 `system_available_at`。每个水位还必须保存 `watermark_computed_at`、stage、purpose、stratum、scope snapshot、未闭合 gap 与 terminal-state 统计。

### 4.3 状态与原因码

对象、字段和枚举以《统一数据、时间与决策契约》全文为 schema 权威；其第 17 节是状态/reason key 的唯一 registry。本计划只能引用相应 canonical key；CI identifier linter 对未知 key 直接失败，禁止在测试文件中维护第二份同义枚举。

## 5. Provisional 日报 SLO

下列值在 M0 作为 `provisional_slo_v1` 冻结，用于 M1/M2 shadow，不是对外产品承诺。M1 结束时只允许通过版本化变更门禁产生 `production_slo_v1`，必须保留旧结果、说明差异并重跑本节测试；不得回写 provisional 历史。

| 配置键 | v0.2 provisional 值 |
|---|---:|
| report_publish_grace_minutes | 5 |
| report_on_time_rate_30d_min | 0.99 |
| cutoff_lag_per_edition_hard_max_minutes | 60 |
| rolling_cutoff_lag_p95_minutes_max | 45 |
| critical_stratum_watermark_lag_minutes_max | 60 |
| normal_edition_collection_opportunity_success_min | 0.95 |
| normal_edition_parse_success_min | 0.98 |
| normal_edition_provenance_complete_min | 0.995 |

单期正常版必须通过发布宽限、`cutoff_lag_per_edition_hard_max_minutes`、水位、采集、解析和 provenance 门槛；滚动准时率与 cutoff-lag P95 只决定服务级状态。影子运行未积累 60 个计划 edition 前，`service_slo_status=warming_up`，可以按单期门槛标记 edition，但不得声称已达到 30 天服务 SLO。未满足适用门槛时可以按时发布 degraded_edition，但必须展示触发字段、实际值、阈值、受影响分层和上述原因码。

`slo_config_version` 还必须冻结计划 slot 分母、30 个日历日窗口边界、时区、P95 估计方法与舍入、缺失/取消 slot 的处理。准时率分母是冻结 schedule manifest 推导的全部计划 slot；未发布 slot 必须计为不准时并投影为 failed，不能从分母移除。首版 P95 使用 nearest-rank `ceil(0.95*n)`；没有 `publication_event_id` 的 slot 不参与 cutoff-lag 数值分布，但会直接损害 service availability/准时状态，且不存在所谓 failed edition。

## 6. M0 契约自检

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| CTR-001 | M0 | P0 | phase-exit | 对 00–05 运行 identifier/schema linter | 对象、字段、run mode、状态与 reason code 全部解析到 05 的唯一 registry；未知或同义 key 数为 0 |
| CTR-002 | M0 | P0 | phase-exit | 从 05 的逐对象 archetype/time-profile registry 生成 JSON Schema 与 SQL DDL，并载入跨 Object/Record/Event ID 碰撞、孤儿 registry、伪父 ID、未登记时间 profile、错误双时间和裸多态引用反例 | schema 可编译；四种 archetype 与全部 time profile 分别穷尽且互斥；每个领域 ID 由 GlobalIdentityRegistry 唯一拥有，kind 子表/具体表双向 deferred 闭合；typed composite FK、快照、用途资格和时间反例均按预期通过或失败；`*Version/*Snapshot` 通配推导会失败 |
| CTR-003 | M0 | P0 | phase-exit | 编译 collection、clock、event-type、coverage、detector、emission、sequential-hypothesis、ranking、attention、report-schedule、report-pipeline、radar-pipeline、presentation-template、UI-bundle、delivery、SLO、evaluation、annotation、model-task、preservation、test-catalog 与 test-governance manifests | 每份 manifest 有版本/hash/owner；clock 阈值/quorum/恢复、typed event payload、required pipeline/comparison keys、cadence、baseline、连续检验、注意力/交付、模型 egress、claim-slot/render schema、radar head dominance/epoch、随机种子、anchor deadline、rights/preservation 依赖和单期/滚动 SLO 均必填且类型正确 |
| CTR-004 | M0 | P0 | phase-exit | 穷举 EventTypeRegistryManifest、EventTypeDefinition、EventStateDefinition/TransitionDefinition 与 EventApiAlias；注入缺 transition child、非法 pair/guard、错误 initial state、跳号/错 predecessor、API 第二 ID，并对 RADAR revision=1/2 篡改 previous snapshot、对 REVOCATION_EPOCH 篡改 from/to epoch | EventBase 命中唯一 definition；from/to 命中签名 transition child且 typed guard 通过，API alias 等于同一 event_id。RADAR revision=1 predecessor/previous 均空，后续均非空且 previous 等于 predecessor snapshot/surface；revocation to=from+1 且等于 domain head+1；未知 type/pair/alias、第二 ID、错误 aggregate/payload均 fail closed |
| CTR-005 | M0 | P0 | phase-exit | 为 M0–M5 的每种 gate 生成 TestCatalogManifest | 自动包含所有 `introduced_phase <= current_phase` 且 applicable 的定义版本，并冻结 governance policy、catalog hash 与排除依据；零测试、未知 inherited 字段、漏掉历史阻断项或临时手选均失败 |
| CTR-006 | M0 | P0 | phase-exit | 静态分析全球域与个人域的数据流/服务身份策略 | 全球服务不可读 private query、conversation、memory 或 correction proposal；个人内容进入全局长期日志/缓存的允许路径数为 0 |
| CTR-007 | M0 | P0 | phase-exit | 对历史 P0 分别尝试 applicability=false/空/未知字段、introduced_phase 后移、P0→P1、blocking→none、oracle 恒真、fixture 缩弱，并用密码学有效但无权/过期/已撤销的 key 签名 | TestDefinitionVersion 编译、授权或强度比较失败并 fail closed；旧强版本仍进入 TestCatalogManifest 且阻断；任何 P0 applicability 不等于 always、阶段后移或强度下降均失败 |
| CTR-008 | M0 | P0 | phase-exit | 同一 TestDefinitionVersion 用相同 catalog 连跑两次，一次 pass、一次 fail，再生成 gate 结论 | 两次执行分别生成不可变 TestRun/TestResult；Definition checksum 不变；GateDecision 绑定完整 catalog/run/result IDs 并因 fail=blocked，不能覆盖首个结果、择优挑 run 或把执行字段写回定义 |
| CTR-009 | M0 | P0 | phase-exit | 按 TestGovernancePolicy 轮换 SigningKeyVersion；分别使用获准 quorum、单人自批、用途不符、自然过期、SIGNING_KEY_STATE 撤销/compromised key 和 gate 后补签生成 ApprovalDecision | 只有在 effective/expires 区间内、当前 state=active、用途匹配且达到独立 quorum 的审批可生效；撤销/compromised 只追加连续 revision 的事件且不可回到 active；其余 fail closed；ApprovalDecision 绑定 old/new hash 与结构化 diff，晚签不得追认既往 gate |
| CTR-010 | M0 | P0 | phase-exit | 删除一个适用 TestResult、伪造不属于 catalog 的 result、复用另一 config/fixture 的 run，或令 GateDecision 只引用通过项 | catalog-definition-run-result-gate FK/哈希闭合；缺失、越界或输入版本不一致均使 GateDecision=blocked；每个 applicable definition 恰有一个本次 gate 可接受的 terminal result |
| CTR-011 | M0 | P0 | phase-exit | 在 M2 令 M1 的 COV-016 失败，在 M5 release 令早期 GOV-001 失败，并放入一个 blocking=none 的失败对照 | 三项都进入对应 TestCatalogManifest；两个 inherited applicable blocking failure 分别阻断当前及未来同类 gate，none 仅记录不阻断；不得因 introduced phase 已退出而忽略回归 |
| CTR-012 | M0 | P0 | phase-exit | 对 05 archetype 与 time-profile registry 做双向集合对账；分别删除 EvidenceUnit、SignalEvidenceLink、PurposeAuthorization、ReportItemPlacement 的 time profile，或把一个对象放入两类 | archetype 与 time profile 各自 missing/extra/duplicate 均为 0；每个 immutable record 至少有规范 system-availability time；任一删项/重项使 schema 编译失败，as-known T 不得读到 T 后记录 |
| CTR-013 | M0 | P0 | phase-exit | 两个写入域对同一 Signal/RightsGrant/ReportSlot/RadarSurface/RevocationDomain/WatermarkGap/MemoryCandidate/CorrectionProposal/SigningKey expected head 写相反排他终态，并注入跳号 revision、错误 predecessor 与事件类型缺 child | 每个 aggregate+family+revision 只允许一个 winner；predecessor 同 aggregate/family 且 revision-1；RADAR_PUBLICATION、REVOCATION_EPOCH、WATERMARK_GAP_STATE、SIGNING_KEY_STATE、memory revoke、proposal withdraw 均按冻结 transition table 执行，失败方保留 attempt 而不产生矛盾当前状态 |
| CTR-014 | M0 | P0 | phase-exit | 从 claim-slot schema 生成 min=2/max=3 units，注入 ordinal/manifest/hash 撞 ID；再对 PresentationRenderPlan 写同 event 第二 plan、duplicate order、裸 referenced identity、跨 event claim/citation、kind 与 1:1 child 不符或双 child，并令 SourceTextRef 同时/均不引用 ClaimCitation 与 RawSourceListingReference | ordinals 1..max 的 ClaimGenerationUnit ID 唯一且前 min 个必须 claim；plan 对 presentation event 唯一，unit 以 typed container FK 和 plan/channel/locale/container/order 唯一，恰有一个 kind-specific child；SourceTextRef 内两类 source ref 再 XOR 且 event/container/channel/locale 一致，任一反例 fail closed |
| CTR-015 | M0 | P0 | phase-exit | 100 个并发事务对同 scope/policy/semantics/kind/typed inputs/strata/role 提交随机 CoverageItem ID，并构造真实 policy/role 变化对照 | 数据库重算 canonical projection key 与 namespace UUIDv5，完整 key 唯一；同义事务只产生一个 CoverageItem 和 generation unit，漏建/重复产生 WatermarkGap；真实决定因子变化生成不同 ID |
| CTR-016 | M0 | P0 | phase-exit | 对 EventCausalParent 写自环、二节点/长环、晚于 child 的 parent、同域逆 sequence、无 queue proof 跨域边、旧事件迟到边和两个并发反向边 | 复合主键、自环/时间/sequence/queue-proof 与 serializable/deferred DAG 门禁拒绝；并发至多一个提交，迟到边不改变旧 as-of，合法 DAG 以固定 tie-break 稳定拓扑回放 |
| CTR-017 | M0 | P0 | phase-exit | 对同 manifest kind×canonical scope 并发写两条相同 revision/重叠区间、各指向不同签名合法 manifest 的 authoritative activation，并另建 shadow | ManifestActivationDecision 的 typed target、revision-1 predecessor FK、UNIQUE(series,revision)、expected-head CAS 与 authoritative range exclusion 只允许一个 winner；shadow 不进入正式分母/水位/head/gate |
| CTR-018 | M0 | P0 | phase-exit | SourceEndpoint V1 已被 V2 取代后构造含 V1+V2/只含 V1/漏 E/额外 E2 的 SourceRegistrySnapshot；另对含 record/value 的 snapshot 使用错误 stable-object profile | 每类 snapshot 命中唯一 SnapshotMembershipProfile；subject×role unit 与 decision 唯一，selected typed member、snapshot child、terminal units 与 as-of projection 四方集合相等，否则 commit 失败 |
| CTR-019 | M0 | P0 | phase-exit | 先提交 pending immutable ModelInvocation，数分钟后 callback 创建 receipt/output；另尝试 Invocation 必填未来 output FK、nullable 后 UPDATE 或同事务预造 output | 唯一合法方向为 Invocation←accepted ResponseReceipt←OutputArtifact；pending 可先提交，后续事务零 UPDATE，receipt 对 invocation terminal 唯一且 output 恰好复合引用 accepted receipt |
| CTR-020 | M0 | P0 | phase-exit | SnapshotMembershipProfile P1 已由 P2 取代，T3 snapshot 仍选择内部自洽但漏新 role 的 P1，另选择 shadow/future profile | snapshot 复合绑定 type/scope/profile/authoritative activation，effective range 同时覆盖 linearization/as_of；stale/shadow/future profile 在生成 membership unit 前失败 |

## 7. P0 架构与证据不变量

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| INV-001 | M4 | P0 | release | 固定全局语料、配置和随机种子，加载两个相反个人画像、点击史和信念库 | global_radar_snapshot_id、candidate_ids、feature_artifact_ids、selection_decision_ids 与 ReportEdition 项目顺序逐字节一致；雷达身份读取个人库的审计事件数等于 0 |
| INV-002 | M4 | P0 | release | 对同一显式问题分别加“我极度看好”和“我极度看空”的前序对话 | 第一阶段输入不含历史消息、user_principal_id、用户 embedding 或记忆；neutral_query_hash、retrieved_evidence_unit_ids 与 evidence_scope_ids 一致；第二阶段差异只能出现在 personal_interpretation |
| INV-003 | M2 | P0 | release | 对 factual/source-claim 分别提供正确来源、无关段落、否定句和单位错配段落 | 每个事实或“来源说了什么”的 ReportClaim 同时通过 item_version_id、evidence_scope_id 和 entailment_result=entailed；后三个反例分别返回 EVIDENCE_NOT_ENTAILED 或 CLAIM_SCOPE_MISMATCH 并阻断对应断言发布 |
| INV-004 | M2 | P0 | release | 来源 A 与来源 B 对同一外部事实冲突 | 保存两条分别归属来源的主张；综合 ReportClaim 的 epistemic_status=disputed，reason_codes 包含 SOURCE_CONFLICT；不得渲染为无争议 external_world_state |
| INV-005 | M3 | P0 | release | 新模型重分析一年前资料 | 旧 edition hash、旧 analysis_run、旧证据引用不变；新输出拥有新 analysis_run_id 和 run_mode |
| INV-006 | M3 | P0 | release | 查询“当时知道什么”和“今天如何回看” | 前者所有输入的 system_available_at 不晚于 as_of；后者允许新资料但每条后见信息带 retrospective 标志 |
| INV-007 | M4 | P0 | release | 两个用户提交相反的全局纠错建议，其中一个在审核前 withdraw，另一个通过公共证据审核 | 只生成个人域 CorrectionProposal；withdraw 追加 CORRECTION_PROPOSAL_DECISION 并按 expected-head CAS 进入 withdrawn，不能覆盖旧决定；审核通过前全局快照不变，通过后只生成公共命题/证据且不含用户特征的 CorrectionEvent 与审核依据 |
| INV-008 | M2 | P0 | release | “采购增加可能意味着产能瓶颈”，证据只直接支持采购事实 | 该句只能标 assertion_type=ai_inference、entailment_result=not_applicable，并保存 premise scopes、反证、替代解释和 inference_support_status；标成 external_world_state 或缺失前提时以 INFERENCE_UNSUPPORTED 阻断 |
| INV-009 | M3 | P0 | release | v2 在 T3 才被系统发现，但业务 valid_effective_at=T2；ActorAction 同时经历计划→执行→取消 | EventBase 必填 target/successor、event_system_available_at、valid_effective_at、causal sequence；旧行 checksum 不变；as-known T2 见 v1，as-known T4 对 valid-time T2 见 v2，projected system_to=T3/valid_to=T2 |
| INV-010 | M2 | P0 | release | 证据只显示 A/B 同期相关，另有来源声称“A 导致 B” | 来源句只能标 source_causal_claim 且只证明“来源声称”；AI 输出最多 observed_association；若标 ai_causal_inference 却无时序/混杂/机制或干预证据，则 INFERENCE_UNSUPPORTED 并阻断因果措辞 |

## 8. U/O/C、采集机会与覆盖测试

各处理目的的集合必须分开：O_acquire、O_extract、O_model:local、O_model:{provider_id}、O_signal、O_display 和 O_prevalence。C 不再使用“成功端点数 / 可观察端点数”，而使用窗口内成功的 collection_opportunity 数 / scheduled_collection_opportunity 数；来源多样性另按 publisher、account、source_lineage 和 owner_group 报告。

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| COV-001 | M2 | P0 | phase-exit | 95% 新输入来自美英科技媒体，其他格有合格最低样本 | prevalence_lens 保留观测分布；exploration_lens 达到冻结配额或生成 QUOTA_INFEASIBLE；缺格不以头部内容补位 |
| COV-002 | M1 | P0 | phase-exit | 来源允许采集和内部全文处理，禁止外部模型，仅允许短引文展示 | collection opportunity 属于 O_acquire；捕获版本属于 O_extract/O_model:local，不属于 O_model:{provider_id}；展示投影不超过短引文；外部模型任务返回 MODEL_TRANSFER_FORBIDDEN |
| COV-003 | M1 | P0 | release | 某地区一半计划采集机会失败 | 成功机会数和应执行机会数正确；状态为 COLLECTION_MISSING；opportunity_completion 下降；相关升温、衰退和跨层比较暂停或降级 |
| COV-004A | M3 | P0 | release | 同一来源内容和主题比例不变，只把抓取频率加倍 | 原始 capture 数可变；canonical item、event、稳定占比和信号准入不变；不得生成升温 |
| COV-004B | M3 | P0 | release | 新增一批来源，使来源数翻倍，但各层主题分布与纳入概率已知 | 原始计数变化标 COVERAGE_SHIFT；校正后的同框架趋势差异不超过版本化 tolerance；不得把新增来源效应称为世界升温 |
| COV-005 | M3 | P0 | release | 一份 PR 原稿、100 篇转载、改写和跨语言翻译 | 文档节点为 101，传播谱系为 1，事实起点为 1；传播规模可增加，独立支持与行动者采纳不增加 |
| COV-006 | M1 | P1 | phase-exit | 同一集团多个品牌发布相似内容，另有一组依赖关系未知 | 已知 owner_group_count 为 1；所有权集中度按集团计算；未知关系标 dependency_unknown 并分别输出独立性下界与上界，不自动算独立或破坏性合并 |
| COV-007 | M2 | P1 | phase-exit | 隐藏一个主要地区或语言后重算 | 记录固定框架和当前框架两组指标；排名翻转率与 top-K overlap 使用冻结 tolerance；超限时 reason_codes 包含 STRATUM_WATERMARK_LAG、COVERAGE_SHIFT 或 DEGRADED_COVERAGE |
| COV-008 | M2 | P1 | phase-exit | 低资源语言处理比英语慢 | 按语言输出 discovery_delay 与 processing delay 的 P50/P95；迟到稿标 DISCOVERY_DELAY 或 PROCESSING_BACKFILL，不生成伪升温 |
| COV-009 | M2 | P0 | release | 提高小语种探索曝光 | 只改变 allocation_lane=coverage_floor 或 exploration surface；O_prevalence 的 numerator、denominator、rank 不变 |
| COV-010 | M2 | P0 | release | 固定快照、配置、代码与种子重复运行 | candidate IDs、allocation_lane、surface placement、顺序和 reason_codes 逐字节一致 |
| COV-011 | M2 | P1 | phase-exit | 一个合格分层格持续欠配额 | 生成 coverage_debt_id、age、reason_code 和 next_rotation_at；不得静默删格 |
| COV-012 | M2 | P1 | phase-exit | 小规模群体的 observation_confidence=C1，与大规模独立测量的 observation_confidence=C3，且两者命题相反 | 两者可展示，但 coverage allocation 不改变 evidence_confidence 或 prevalence magnitude |
| COV-013 | M1 | P0 | release | 已登记目标来源变为受限或失联 | 仍留在固定 U cohort；对应处理目的 O/U 下降；策略新版移除需 change event，旧 cohort 指标保持可查 |
| COV-014 | M1 | P0 | release | 同一 RSS 从一个端点拆成 100 个栏目，再重新合并 | canonical publisher/lineage 覆盖、计划采集机会和内容完整性指标在 tolerance 内不变；endpoint_count 仅作运维量 |
| COV-015 | M1 | P0 | release | 一个 API 端点代表 100 个可枚举账号，其中只采到 20 个 | endpoint 可用率可为 100%，但 account_frame_coverage 必须为 20/100，不能报告完整公众覆盖 |
| COV-016 | M1 | P0 | phase-exit | 月更端点处于小时窗口且本小时无计划任务 | 不进入本小时 scheduled opportunities 分母；到了计划周期未执行则返回 COLLECTION_OPPORTUNITY_MISSED |
| COV-017 | M1 | P0 | release | API 返回 HTTP 200，但分页游标跳号或停止前进 | endpoint_health 不得掩盖内容缺口；状态含 CURSOR_GAP 或 PAGINATION_INCOMPLETE；本机会不计完整成功 |
| COV-018 | M1 | P0 | release | 分别构造健康零结果、抓取失败、健康来源沉默和不可访问来源 | 精确输出 OBSERVED_ZERO、COLLECTION_MISSING、SOURCE_SILENT、NOT_OBSERVABLE；只有 OBSERVED_ZERO 可作为有限负证据 |
| COV-019 | M1 | P0 | phase-exit | 同一来源的计划机会和捕获版本在 acquisition、signal、display 三个目的下权限不同 | O_acquire 按计划机会计算，O_signal/O_display 按版本或投影计算，各用各自分母；不得用 acquisition 达标替代 signal/display 达标 |
| COV-020 | M1 | P0 | release | 将一个预期每 5 分钟更新的 feed 的采集计划静默降为每日一次 | 旧 collection_plan cohort 的 schedule adherence/完成率不变；新 plan 必须有 change event、依据和缺失敏感性，不能只靠减少 opportunity 让健康度上升 |
| COV-021 | M2 | P0 | release | ranking manifest 从 required_comparison_keys 删除一个持续偏慢语言 | 产生新 manifest/coverage policy version、degraded scope 与排名敏感性；同一 global comparison scope 不得因删 key 被标 normal |
| COV-022 | M1 | P0 | release | 某版本允许 provider A 做一次性推理，但未授权训练；目标模型也不能样本级删除 | 版本可进 O_model:{provider_id}，默认不进 O_train:{model_id/purpose}；训练集构建返回 PURPOSE_TRAIN_DENIED，推理许可不得被解释成微调许可 |
| COV-023 | M1 | P0 | release | 游标依次推进 A→B，随后重置到 A 并重新抓取，另模拟 worker 覆盖当前 cursor 行 | 每次变化创建不可变 ContentCursorCheckpoint、previous checkpoint、transition reason 和受控 sequence；A/B checkpoint checksum 不变；覆盖旧 checkpoint 被 schema 拒绝，重抓不制造重复逻辑到达 |
| COV-024 | M1 | P0 | release | 冻结的 CollectionPlanManifest 确定应有 12 个 opportunity，但调度器宕机只物化 11 行，并尝试按现存行计算成功率 | 由 manifest 确定性派生的第 12 个 opportunity ID 仍在分母，对账生成/投影为 COLLECTION_OPPORTUNITY_MISSED；完成率按 12 个计算，不能以漏建 CollectionOpportunity 美化健康度 |
| COV-025 | M2 | P0 | phase-exit | 一个内容质量、证据和权限均达标的项目，其 domain 与 publisher role 均为 unknown | 保留两个 unknown，不得因分类缺失丢弃或强塞进已知格；项目仍进入 allocation_lane=random_exploration 的 open-world unknown 子分层并参与冻结配额/选择，prevalence 不因探索曝光被改写 |
| COV-027 | M1 | P1 | service-claim | 冻结目录/API frame 返回 1,000 个逻辑流，但只为 10 个易接入来源创建准入决定并截断后续分页 | SourceDiscoveryFrameManifest 的 receipts 可重建 1,000 个 opportunities，且各有唯一 admit/reject/duplicate/failed terminal；漏行形成 gap，覆盖声明报告分层候选→准入率与拒绝原因 |
| COV-028 | M1 | P1 | service-claim | 每月应为 100 个地区×语言格运行来源发现，但只为准入率最高的 10 格创建完整 frame，其余不建 frame | SourceDiscoveryProgramManifest 预生成全部 FrameOpportunity 与 run/skipped/failed terminal；run 复合绑定唯一 frame，缺 frame 形成 gap并阻断跨格发现覆盖/多样性声明 |
| COV-026 | M2 | P0 | phase-exit | 创建 CoverageDebt 后跨越 10 天再查询，并尝试把 record 中的 `age=0` 原地更新为 10 | 权威 record 只保存不可变 `opened_at`，age 必须按查询 as-of 计算；写入/更新持久化 age 失败，偿还或豁免只追加 COVERAGE_DEBT_STATE 且旧 record checksum 不变 |
| LAN-001 | M1 | P0 | phase-exit | 每种正式语言的独立冻结评测集 | 阈值、样本量、双语评审、严重意义反转、实体和引语归属均直接引用 docs/01-global-information-coverage-matrix.md 第 15.1 节当前版本；评测 artifact 记录该文档版本和 hash，不复制另一套阈值 |
| LAN-002 | M2 | P1 | phase-exit | language × assertion_type 分层金标，含否定、跨句主体、表格数字/单位与来源自述 | 每层报告 false-support rate、abstention rate、coverage 和 CI；超过冻结门槛时不得发布 confirmed fact，只能降为 source claim、人工复核或弃答 |

## 9. 时间、版本、水位与日报 SLO

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| TIM-001 | M2 | P0 | release | item_first_seen_at 分别为 07:59:59、08:00:00、18:59:59、19:00:00 | 按半开区间只归属一个 nominal_window；每条只首次发布一次 |
| TIM-002 | M2 | P0 | release | 07:59:59 item_first_seen_at，08:03 才 version_available_at | 上午版不读取；下一版标 PROCESSING_BACKFILL；保留 nominal_window 与实际展示版 |
| TIM-003 | M2 | P0 | release | 一篇一周前发布的旧文今天首次被发现 | reason_code=DISCOVERY_DELAY；展示原发布时间与发现延迟；不得当作今天发生 |
| TIM-004 | M1 | P0 | phase-exit | 来源静默修改标题或正文 | 生成新 RawItemVersion、hash、version_observed_at 和 version_available_at；旧版本不覆盖 |
| TIM-005 | M2 | P0 | release | 一周前条目在 version_observed_at=18:50 增加重大新行动，19:03 才完成派生处理 | delta 标 MATERIAL_UPDATE；按 18:50 的 information_arrival_at 归入名义窗口并补录一次；不能按旧 item_first_seen_at 回填一周前 |
| TIM-006 | M2 | P0 | release | 来源更正与撤稿 | 更正标 CORRECTION，撤稿标 RETRACTION；相关当前信号重算；旧 edition 通过状态事件显示而不静默改版 |
| TIM-007 | M2 | P0 | release | 原文 07:30 可见，翻译 08:10、聚类 08:20、观察 08:25 才产生；通过真实 08:00 ReportEdition 查询/渲染路径回放 | edition 的候选、ReportClaim、摘要、证据和渲染均不得读取后三者；每个派生对象的 system_available_at 可审计，绕过 as-of 的缓存或预计算结果同样失败 |
| TIM-008 | M2 | P0 | normal-edition | 英语水位 07:45，阿语水位 07:05 | 跨分层比较的 comparison_watermark 等于冻结政策计算值，默认不晚于最慢纳入分层；晚于共同水位的数据只能进局部快讯或补录，不能进入全局比较 |
| TIM-009 | M2 | P0 | service-claim | 连续 30 天共 60 个 ReportScheduleSlot | 有 PublicationEvent 且 committed_at 不晚于 scheduled_publish_at 加 grace 的比例不低于准时率；created/preview/attempt 不算发布；未满 60 期时 service_slo_status=warming_up；breach 不改写当前 edition_status |
| TIM-010 | M2 | P0 | normal-edition | 08:00 准时生成，但 data_cutoff 为 02:00 | cutoff_lag_minutes 超 cutoff_lag_per_edition_hard_max_minutes，edition_status=degraded，reason_code=DEGRADED_CUTOFF_LAG；不得以聚合 P95 或准时生成掩盖陈旧 |
| TIM-011 | M2 | P0 | normal-edition | 任一关键分层水位落后 90 分钟或计划采集成功率低于阈值 | edition_status=degraded；展示受影响分层、实际值与阈值；不得标“完整全球报告” |
| TIM-012 | M2 | P0 | phase-exit | 抽取两个连续日报及所有补录 | nominal windows 无重叠无空档；每个可报告 information arrival 恰有一个 `ReportItemPlacement.is_first_publication=true`，并通过 edition 关联唯一 `publication_event_id`；补录通过 `backfill_of_report_schedule_slot_id` 关联；format_only 与 non_reportable metadata_update 不产生首发 |
| TIM-013 | M2 | P0 | normal-edition | 一个 arrival_at=06:00 的旧输入到 07:58 才完成，07:40 后的新输入仍未处理 | 该键 processing_watermark.frontier_at 不得因 system_available_at=07:58 而越过 06:00 后首个未闭合输入；记录 WATERMARK_INPUT_GAP；comparison_watermark 使用 frontier_at 而非最后任务时间 |
| TIM-014 | M1 | P0 | release | 采集节点快 8 分钟、派生节点慢 12 分钟，随后发生 NTP 回拨与进程重启 | 入口权威时钟与 ingest_sequence 保持 happens-before；异常对象 time_quality=degraded、reason=CLOCK_UNTRUSTED，被隔离出精确窗口/lead-time；edition 降级且无未来对象进入 T 查询 |
| TIM-015 | M2 | P0 | normal-edition | 60 期中 58 期 cutoff lag=5 分钟、2 期=180 分钟，rolling P95 仍低于阈值 | 两个 180 分钟 edition 都因单期 hard max 为 degraded；rolling 指标只更新 service_slo_status，不得反向改写 edition_status |
| TIM-016 | M2 | P0 | release | 30 天计划 60 个 slot，其中 2 个完全未发布；另以不同 quantile 插值法重算 | 两个 slot_status=failed 且无 ReportEdition/PublicationEvent，准时率分母仍为 60；P95 严格使用 SLOConfig；不得通过删 slot、伪造 failed edition 或换算法美化 SLO |
| TIM-017 | M2 | P0 | release | 来源把已报道事件的自报发布时间从本周改为一年前，导致时间线语义变化 | 系统 item/version 时间不改；RevisionAssessmentVersion 判 metadata_update/reportable，以 version_observed_at 进入更正区并标 SOURCE_TIME_CHANGE；不得静默重排旧 edition |
| TIM-018 | M2 | P0 | release | metadata update 初判 unknown 并入日报，次日新规则判 non_reportable | RawItemVersion 与旧 assessment checksum 不变；新增 RevisionAssessmentVersion+SupersessionEvent，以 decision_system_available_at 追加 REVISION_ASSESSMENT_CORRECTION 并重算当前投影，不倒填旧报告 |
| TIM-019 | M1 | P0 | release | skew 分别为 4999ms/5001ms、quorum 失效 119s/121s，并测试 rollback 与恢复 | 严格按 clock_policy_v1 边界判 trusted/degraded；rollback 立即失败；只有 5 分钟内连续 5 次 quorum 健康且 sequence 连续才恢复，节点不能自报 30 分钟阈值 |
| TIM-020 | M2 | P0 | release | 一个 slot 经两次失败 attempt 后完全漏发，另一个第三次原子提交成功 | 前者只有 failed slot/attempts，无 edition/event；后者恰有一对 PublicationEvent/ReportEdition；created_at 不算 committed，slot/edition FK 和服务分母唯一 |
| TIM-021 | M2 | P0 | normal-edition | configured cutoff=07:59、required processing frontier=07:30、selection completeness frontier=06:00 | data_cutoff=min(...)=06:00，cutoff_lag 按 06:00 重算并触发 DEGRADED_CUTOFF_LAG；不得声称处理到 07:59 |
| TIM-022 | M2 | P0 | service-claim | 预先冻结 30 天每日两期 schedule manifest；令服务整期宕机而漏建一个 slot，并在窗口开始后尝试改 recurrence/时区 | manifest 确定性推导 60 个 slot ID，漏建项仍作为 failed 进入分母；状态变化只追加 ReportSlotStateEvent；事后 schedule 变更不得改历史分母，时区与 tzdb version 可重放 |
| TIM-023 | M2 | P0 | normal-edition | raw/parse 水位新鲜，但本期所有 detector worker 均未运行，因而 candidate 集合为空、SelectionDecision 也为空 | 冻结的 required `stage×purpose×stratum_version_id` 集合非空且至少含 eligibility/normalization、candidate generation、selection、claim generation；每个 eligible CoverageItem×required DetectorVersion 有确定性 generation unit，缺 terminal decision 形成 WatermarkGap；selection frontier 不得对空集真空推进，edition 必须 degraded/blocked 而不能以“零候选”标 normal |
| TIM-024 | M2 | P0 | release | 两个 worker 对同一 ReportScheduleSlot 使用不同 idempotency key 并发原子提交 initial edition | 唯一约束与 fenced slot transition 只允许一对 initial PublicationEvent/ReportEdition 成功；失败方留下冲突 attempt，不能生成第二个成功事件；后续修订必须使用独立 amendment/revision 身份 |
| TIM-025 | M2 | P0 | release | 同一 ReportableArrival 因 processing backfill、任务重试而被连续两个 slot 同时选中，并分别尝试声明首次发布；另在 initial publication 写完 edition 后故障而漏写 placements | PublicationEvent、ReportEdition 与完整有序 placements 在同一事务提交；每 arrival 只允许一个 first，同一 `(report_edition_id, information_arrival_id)` 只允许一行，edition 冻结顺序与 placement 集合 deferred 对账；后续 placement 标 backfill 并指向原名义 slot；冲突/缺行回滚整笔发布，不能留下已发布空壳 edition |
| TIM-026 | M2 | P0 | normal-edition | 一个 WatermarkGap 仍为 open，worker 直接删除 gap 行或写新 ProcessingWatermark 越过它；另构造合法 closed 与 superseded 转换 | open gap 阻断 frontier；只能用 WATERMARK_GAP_STATE 的连续 revision/expected-head CAS 转为 closed/superseded 并引用 resolution evidence，删除行、跳 revision、错误 predecessor 或无事件越过均失败 |
| TIM-027 | M2 | P0 | release | 一个 selected 候选仅来自 ObservationSeriesSnapshot、没有可伪造的 RawItem arrival；另放入 not_selected 候选，并令卡片清单与 edition 顺序少一项 | selected unit 恰有一个 ReportCardPlacement，绑定 unit/decision/candidate/surface/card order；candidate-only 卡片可无 SignalVersion 但显式标记，不能伪造 ReportableArrival；not_selected/failed 无卡片；Publication/Edition 与完整 item/card 两套 placements 同事务，缺卡或顺序不一致整笔失败 |
| TIM-028 | M2 | P0 | release | 一个 card 有两句 ReportClaim；分别漏写一句、重复 claim_order、把另一候选的 claim 跨卡引用，并在发布后才尝试补写 | ReportClaim 必须与 Publication/Edition/placements 同事务；presentation event、typed ReportEdition/ReportCardPlacement container 与顺序复合一致，edition ordered claim 清单 deferred 对账；任一漏句/跨卡/重序使整笔提交失败，不存在先发布后补 claim |
| TIM-029 | M2 | P0 | release | selected card 与世界概览分别令 claim 清单为零、漏一个 required claim slot、把 required slot 标 not_applicable；另在 title、caption、tooltip、alt/ARIA、Markdown 隐藏区、通知和导出各拼接一句未登记动态推断或篡改已验文本 | ClaimGenerationUnit/Decision、ReportClaim、PresentationRenderPlan/PresentationContentUnit 与最终 DOM/序列化输出在 container/slot/channel/locale/order/kind/ref/hash 上双向相等；零/漏/非法 not_applicable 返回 CLAIM_COLLECTION_INCOMPLETE，额外/缺失/变 hash 文本返回 UNAUDITED_PRESENTATION_CONTENT；整个 Publication/Amendment 回滚且无先发布后旁路 |
| TIM-030 | M2 | P0 | release | 对 candidate_count=0 的同一栏目分别构造真实零候选、worker 未运行、open WatermarkGap 与撤权重算，并尝试统一用签名 static-ui 文案“没有值得关注的信号” | manifest 激活 section_empty_state required claim，绑定 selection completeness、watermarks、coverage/rights、观测四态和原因码；真实零可发布准确有限空态，worker/gap/撤权按门禁 failed/unavailable；用静态模板替代动态世界主张返回 CLAIM_COLLECTION_INCOMPLETE |
| TIM-031 | M2 | P1 | release | initial edition 有 A/B；两个连续 amendment 依次删除 A、替换并重排 B，同时让读、缓存、详情和导出交错并尝试拼 base+delta | initial publication 和每个 REPORT_AMENDMENT head 各引用完整 ComposedPresentationSnapshot；ReportViewToken 绑定 head revision/snapshot/epoch/render hash。每个响应完全等于某个 committed head，不得同时含 A、旧 B、新 B；token 越界返回 REPORT_VIEW_TOKEN_SCOPE_MISMATCH |
| TIM-032 | M2 | P1 | release | 中文 claim 含否定、数值/单位、来源归属、AI 推断和“可能”；英语 visual、ARIA、tooltip、通知 variants 分别删除限定、改数值或漏推断标记，同时保持各自 hash 自洽 | manifest-required ClaimExpressionVariant 均绑定 TranslationArtifactVersion/ModelOutputArtifact 与 semantic-equivalence；canonical semantic slots 全保留才发布，任一语义漂移返回 CLAIM_EXPRESSION_NOT_EQUIVALENT，客户端临时翻译不可见 |
| TIM-033 | M2 | P1 | release | claim A 由 evidence A 支持，却把合法 source B 标题/quote 邻接并标 evidence；另把 context/contradicts 改支持标签，并尝试用 nullable ClaimCitation 表达无 claim 的原始资料 | ClaimCitation 的 claim/source/EvidenceScope/rights/citation role/hash 复合一致且 report_claim_id 非空；只有 entails/source_asserts 可用支持标签。原始资料必须用无 claim 的 RawSourceListingReference 绑定 ReportItemPlacement；两类 XOR，无关或错标返回 CITATION_CLAIM_MISMATCH |

## 10. 合规、删除与历史视图

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| GOV-001 | M1 | P0 | release | 来源许可仅允许元数据和短引文 | 不保存全文；派生对象和展示遵守相同许可；禁止目的返回对应 PURPOSE reason code |
| GOV-002 | M1 | P0 | release | 对带 canary 的内容执行有效删除 | 15 分钟停止展示与新检索，24 小时在线正文/分块/向量/缓存/索引/可识别摘录不可检索，备份隔离且 30 天内过期；墓碑不含 canary |
| GOV-003 | M2 | P0 | release | 被删资料曾出现在旧 edition 和模型摘要 | 旧 selection IDs、顺序和非内容随机 receipt/HMAC 保留；当前访问投影为 content_removed_by_policy 且原因 DELETED_BY_POLICY；原文、excerpt、向量、渲染文本和模型输出中的 canary 全部不可访问 |
| GOV-004 | M3 | P0 | capability-claim | 被删资料属于冻结前瞻候选 | 候选不从评估分母移除；标 EVIDENCE_CENSORED；协议预先规定 censored 的统计处理；能力指标同时报告 censored_count |
| GOV-005 | M1 | P0 | release | 公开网页含联系方式、未成年人或高敏感数据 | 按 docs/01 的隐私等级最小化、隔离和限制模型传输；“公开”不自动变成长期保存依据 |
| GOV-006 | M1 | P0 | release | R1 内容被调度到禁止的第三方模型 | 调用在出站前阻断；审计含 MODEL_TRANSFER_FORBIDDEN；正文未出境 |
| GOV-007 | M2 | P0 | release | 分别在模型调用中、报告渲染中、原子发布提交前提高内容 revocation_epoch | 旧 epoch 任务被取消或 taint；不得持久化/展示其输出；发布门禁读取最新 epoch 并返回 REVOCATION_RACE_BLOCKED；读时投影不被旧缓存绕过 |
| GOV-008 | M1 | P1 | release | 删除内容为低熵电话号码/短句，攻击者枚举公开候选 | 墓碑不暴露裸内容 hash；仅受控 HMAC 或随机 receipt 可用，未授权匹配成功率不高于冻结随机基线 |
| GOV-009 | M1 | P0 | release | A/B 两个合法来源产生相同字节并物理去重；先撤销 A，随后撤销 B | A/B 的 RawArtifact、rights 与 ArtifactBlobBindingVersion 独立；撤 A 追加 BindingRevocationEvent，A 路径失效而 B 按独立法源可用；撤最后授权绑定后原子 BlobDeletionEvent 清除 blob/key，物理 hash 不充当法律身份 |
| GOV-010 | M1 | P0 | release | Grant A 只允许 metadata，Grant B 的 AuthorizedContentScope 允许展示 200 字；先构造 A+Scope B 错配，再对合法 B/scope 分别请求 200/201 字、翻译/摘要、T+31d 展示和 embedding | PurposeAuthorization 对 `(authorized_content_scope_id, rights_grant_version_id, resource_record_identity_id, resource_record_type)` 使用复合 FK，A+B scope 错配失败；合法组合仅 200 字原样片段可获授权，超量、未授权 transform、过期和未授权 derivative 分别阻断；processor/purpose/epoch 也必须一致，`eligible_display=true` 不能绕过 |
| GOV-011 | M1 | P0 | release | 同一 external_pointer 依次 200→404→200，再由两个域近同时写入 timeout/403，并注入一个 time_quality=degraded 的较新观察 | RawArtifact 不变且不含 last_verified/status；每次检查追加 ExternalPointerCheckEvent；按 `(pointer_checked_at,event_system_available_at,event_id)` 唯一 reducer 和冻结枚举投影，403→access_restricted、timeout→indeterminate；最新可信度 degraded 时为 indeterminate 且不回退旧成功；任何视图都不声称本地可恢复正文 |
| GOV-012 | M1 | P0 | release | 网页与恶意 provider 输出要求读取记忆、修改 rights、调用 export/任意 URL；另在派生文本中夹带未授权 R1 fragment | 唯一 egress proxy 的实际字节与 OutboundPayloadManifest/PurposeAuthorization/hash/length 完全相等；未列工具/网络/凭据、私人 canary 外流和控制面写入均失败；tainted 输出只有通过 typed ModelOutputValidation 后可作为数据 |
| GOV-013 | M1 | P0 | release | 对同一 invocation/output/task/schema/validator/field 并发写 passed/failed ModelOutputValidation，另漏一个 manifest-required validator | 先物化确定性 validation units；attempts 与 terminal decisions 分表，`UNIQUE(unit_id)` 使双终态至多一个提交；全部 required units passed 后 typed field 才能下游，漏 unit、非 manifest validator 或择取幸运 pass 均失败 |
| GOV-014 | M1 | P0 | release | provider session S 先保存私人 canary，公共 invocation 的合规字节只发送 `thread_id=S` | remote handle 必须引用递归 ProviderContextSnapshot/effective-context hash；公共任务 transitive private-lineage=0，未登记或私人 context 在出站前失败，公共 artifact/log/report 的 canary 命中数为 0 |
| GOV-015 | M2 | P0 | release | payload 同时依赖 PersonalScope `Dp@7` 与 R1 rights `Dr@11`，在构建、callback、cache、完整物化、首字节和导出时分别只推进一个 domain | 所有 invocation/output/context/callback/cache/token/export/delivery 绑定完整 RevocationDependencySnapshot；任一 head 不匹配时旧 artifact 持久化、callback 接受和内容字节增量均为 0 |
| GOV-016 | M0 | P0 | phase-exit | 同一 gate evaluation 先失败后重跑通过并只选 pass；再在 pass GateDecision 后尝试追加失败 run | run slots/retry policy 预冻结；attempt membership 全量，closure 前不能决定、closure 后不能追加；GateDecision 引用 closed evaluation 全部 results，任一 blocking fail/分歧 blocked/flaky，不能择优洗白 |

### 10.1 长期保存与恢复

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| ARC-001 | M1 | P0 | release | 对一个存储副本人为翻转字节，另一独立副本保持正确 | fixity scrub 检出 checksum/length 不符；损坏副本隔离且不进入抽取；按 PreservationManifest 恢复并追加 repair event |
| ARC-002 | M1 | P0 | phase-exit | 按一个冻结的 `preservation_policy_version` 从备份恢复完整垂直切片 | 原始字节 checksum、稳定/版本 IDs、外键、rights、删除墓碑、双时间和 ledger checkpoint 全部匹配；RestoreTestEvent 引用同一政策版本，RPO/RTO 在该政策门槛内 |
| ARC-003 | M1 | P1 | phase-exit | 旧媒体/文档格式迁移到新可读格式 | 原始 artifact 字节和 ID 不变；迁移结果是带 parser/tool provenance 的 derivative；两者许可和删除级联一致 |
| ARC-004 | M1 | P0 | release | 当前 checksum 算法进入退役流程 | 追加 PreservationManifestVersion、新算法 digest 与 ChecksumMigrationEvent，旧验证链保留；artifact ID 和审计 receipt 不重写，抽样双算法校验通过 |
| ARC-005 | M1 | P0 | release | 轮换 envelope-encryption key，随后模拟旧 key 不可用 | 获准内容可通过新 key 恢复且无明文旁路；已删除/撤权内容不能因备份或旧 key 恢复；key access 事件可审计 |
| ARC-006 | M1 | P0 | release | 撤销最后一个授权 ArtifactBlobBinding 的同时，并发新增一个独立合法 binding | serializable/fenced 事务只允许两种结果：新 binding 先提交并阻止 BlobDeletionEvent，或删除先提交且新 binding 使用新 blob/key；不得复活旧 key、负引用计数或 stale access |
| ARC-007 | M1 | P0 | phase-exit | 分别创建 full_bytes、licensed_excerpt、metadata_only、external_pointer RawArtifact | 前两者强制 blob binding/checksum/key/PreservationManifestVersion；metadata_only 禁 source-content binding 且要求 metadata checksum；external_pointer 禁内容字段并标 external_uncontrolled；各自恢复声明不越界 |
| ARC-008 | M1 | P0 | release | 恢复含 canary 的删除前 T0 备份，而真实 deletion/rights/key/personal-deletion checkpoint 在 T1；另提供回滚或不可达 checkpoint | RecoveryFence 在开放网络/检索/缓存/模型/导出前取得最新独立单调 checkpoint、证明未回滚并 replay 红删/销钥；缺失/回退时 deny-all，canary 不可从 blob/index/cache/report/export/provider retry 取回 |
| ARC-009 | M1 | P0 | release | authority set 已从 A 轮换到 B 后，连同 T0 业务备份恢复旧 manifest/keys/service discovery A，并由 A 返回其宇宙内最新 checkpoint | RecoveryFence 先验证独立 ComplianceAuthorityEpochCheckpoint、外部 current pointer 及 old+new quorum transition chain；authority epoch 落后即 deny-all，不能只在回滚后的 A 中取最大 head |
| ARC-010 | M1 | P0 | release | 服务持有 A epoch 未过期 lease；A→B 轮换后 B 撤销 key/rights，隔离服务仍从旧 A 验 lease并尝试 token/cache/首字节 | lease 签名绑定 authority epoch/root/head/freshness；pointer 切换使全部 A lease 失效，token/cache/provider/首字节前无法证明 current B 即 deny-all，字节与 cache-hit 增量为 0 |

## 11. 弱信号与统计机制

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| SIG-001 | M3 | P1 | phase-exit | 低总量命题持续出现在三种语言、三类独立行动者，并有一项可验证现实行动 | 可进入相应 signal_types，即使不进入 hotspot surface；显示支持度和分母 |
| SIG-002 | M3 | P0 | release | 一个主题从 1 增到 4 | 标 SPARSE_SUPPORT；输出原始值、收缩估计、区间和样本量；不得仅凭 300% 进入 active |
| SIG-003 | M3 | P0 | release | 一万个协调机器人账号同步发布 | attention anomaly 可高；origin/evidence independence 不随帖子数增加；manipulation_risk=high；不得仅凭数量升级 active |
| SIG-004 | M3 | P0 | release | 单一 PR 被翻译到十种语言 | content_distribution 可增加；source_lineage_count 和 actor_adoption 不增加；不得判十语言独立采纳 |
| SIG-005 | M3 | P0 | phase-exit | 三个地区的本地行动者无引用地独立采用同一概念 | actor_adoption 与 diffusion path 增加；每条边关联本地证据和时间 |
| SIG-006 | M3 | P1 | phase-exit | 两个不同现象的英文译文高度相似 | gold cluster IDs 保持分离；如误合并则测试失败，而不是只记录“待审” |
| SIG-007 | M3 | P1 | phase-exit | 讨论上升但立场主要为反对和讽刺 | mention 上升，stance 分布为负；action 不变；报告不得表述为采用增加 |
| SIG-008 | M3 | P1 | phase-exit | 讨论增加但招聘、采购、部署和资本行动无变化 | attention 增强，action stage 不变；missing_action_evidence 明示 |
| SIG-009 | M3 | P0 | release | 注入金标为强反证的独立证据 | 下一运行 counterevidence 包含该 evidence ID；解释置信按冻结状态机下降、disputed 或 falsified；原支持证据保留 |
| SIG-010 | M3 | P1 | phase-exit | 候选消退数月后出现新独立行动 | 产生 reactivated 周期或新信号映射；旧 ID、消退原因和版本仍可查 |
| SIG-011 | M3 | P0 | release | 相关分层来源断流 50%，同时观测主题计数下降 | reason_code=COLLECTION_MISSING；不得产生真实 decline/reversal；当前置信自动提升被阻断 |
| SIG-012 | M3 | P1 | phase-exit | 多来源声称 A 导致 B，但只有时间相关 | 关系最多为 source_claimed_cause 或 observed_association；摘要不得输出 supported_mechanism |
| SIG-013 | M3 | P0 | phase-exit | 周末、节假日和固定月末发布峰值 | 使用同小时/星期/节假日基线后，未超过冻结异常阈值则不触发；baseline_version 和 seasonal_features 可审计 |
| SIG-014 | M3 | P0 | phase-exit | 同时扫描 10,000 个候选，其中按金标仅预设数量异常 | 概率检测器输出 tests_count 与 q_value 并满足冻结 FDR；非概率检测器输出 empirical_false_alarm_rate，不得伪造 p 值 |
| SIG-015 | M3 | P0 | release | 在同一触发窗口重复运行检测和确认，并把同一 API/测量过程切成新的 EvidenceUnit/ObservationVersion ID | confirmation 不得复用触发窗口；即使 ID 不相交，SourceLineage、行动者/行动或 measurement/data-generation process 相同仍不能算独立确认；重叠使用 CONFIRMATION_WINDOW_OVERLAP 且不能升级 |
| SIG-016 | M3 | P0 | phase-exit | 多组低基数序列含零分母、1→4、同生成过程新 ID 和真正独立复现 | 输出有限区间、收缩值和 SPARSE_SUPPORT；零分母不产生无穷值；只有时间增量与谱系/行动者/数据生成过程均满足冻结独立性 oracle 的后续样本可提高确认 |
| SIG-017 | M3 | P1 | phase-exit | 检测器清单与当前阶段 manifest 对照，并在同一 D05 key 下放入两个不同 DetectorVersion | manifest entry 必须 FK 具体 `detector_id/detector_version_id`；只验收 manifest 声明的版本；generation unit 按具体版本区分，缺失实现或仅有展示 key 不得被“全部通过”掩盖；manifest hash 写入运行 |
| SIG-018 | M3 | P0 | release | 对同一 generation unit 并发写 candidate 与 no-candidate；对同一 selection unit 并发写 selected 与 unselected | 每个确定性 generation/selection unit 恰有一个 terminal decision；唯一约束或 expected-head CAS 使冲突方失败，Watermark/edition 不能在矛盾双终态下推进 |
| SIG-019 | M3 | P0 | capability-claim | 365 天每小时动态扫描 10,000 个主题并在每个滚动窗重置 BH，另运行合法 alpha-spending 对照 | 所有 test/candidate/no-candidate/failed 写入同一 SequentialHypothesisFamily ledger，序号/wealth/predecessor 连续；重置/漏账使用 MULTIPLE_TESTING_UNCONTROLLED 并阻断确认、能力声明和晋升 |
| SIG-020 | M3 | P0 | release | 候选 C 出现后按其关键词/链接招募 50 个新站点转载 C，并提供预冻结独立留出来源对照 | SourceDiscoveryDecision/RecruitmentCohort 标 candidate-conditioned；这 50 个来源不得增加 C 的 D07 扩散、独立确认或流行度，留出来源按原独立性规则可用 |
| SIG-021 | M3 | P1 | phase-exit | 合格 unknown/OOD CoverageItem 使全部 detector 返回 no-candidate，另混入无权/低质对照 | 合格项仍确定性物化 PreDetectionExplorationUnit/Decision，selected 只生成 not_a_signal=true 的 ExplorationMaterialPlacement；不合格项不填位，任何项均不增加 candidate/prevalence/命中分母 |
| SIG-022 | M3 | P0 | capability-claim | 对 10,000 个零假设先评分只登记最小 p 赢家；另建 100 个同 scope sibling families 各取 alpha=.05 | 每个 scored opportunity 预先物化且有 generation/ledger terminal；family 是 root alpha 的互斥守恒子分区，`scored=generated=ledger terminals` 且 child debit≤root wealth；只记赢家/拆族返回 MULTIPLE_TESTING_UNCONTROLLED |
| SIG-023 | M3 | P0 | release | C1 条件化招募来源后，这些来源触发同 family 或轻改谓词的 C2 | ConditioningAncestryClosure 覆盖 C1/family/query/cohort/source/CoverageItem/C2；闭包内来源对 C2 的 D07、独立确认和 prevalence 增量为 0，不能仅因 candidate/family ID 不同洗白 |
| SIG-024 | M3 | P1 | phase-exit | 100 个等质 no-candidate CoverageItems 先看内容后只为最吸引人的一个创建探索 unit | 每个 CoverageItem 先有唯一 eligibility unit/decision 与固定证据；terminal 分母=100，缺任一形成 gap，只有 eligible 后才创建随机 exploration unit，不能报告探索预算完成 |
| SIG-025 | M3 | P0 | capability-claim | 全量登记 10,000 个 null test opportunities，但读取 p 值后按从小到大重排 ledger 或只给小 p 分配较大 alpha_i | logical order、threshold reservation 与 predecessor information set 在统计量可读前冻结；验证器仅按 history_<i 重算阈值，任何结果依赖重排/分配均标 MULTIPLE_TESTING_UNCONTROLLED |
| SIG-026 | M3 | P0 | capability-claim | 两个 null tests 共用 U，令 p1=U、p2=1-U；各自边际 uniform，顺序/阈值仅依赖严格历史且 wealth 守恒 | 每项绑定 TestStatisticInputSnapshot、抽样/停止 lineage、filtration 与 dependence cluster；conditional super-uniformity/e-process 条件不成立即 MULTIPLE_TESTING_UNCONTROLLED |

## 12. 分配通道、信号类型、产品表面与确定性

数据契约必须使用三个不同字段：

- signal_types：语义类别，可多选；
- allocation_lane：覆盖矩阵规定的预算通道，每个候选恰有一个主值；
- surface_sections：热点、弱信号、探索、操纵异常等产品位置，可多选。

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| SEL-001 | M3 | P0 | phase-exit | 一个同时满足 emergence、diffusion 且由随机探索入选的候选 | signal_types 含两个值；allocation_lane 恰为一个值；surface_sections 独立记录；不得用单一 channel 字段代替 |
| SEL-002 | M3 | P0 | release | 将同一候选集随机打乱 100 次 | 在相同快照、配置和种子下，candidate IDs、allocation_lane、surface placement、顺序和 reason_codes 每次逐字节相同 |
| SEL-003 | M3 | P0 | phase-exit | 多维配额不可同时满足 | 使用冻结约束优先级；输出 QUOTA_INFEASIBLE、未满足约束和候选缺口；不得静默改权重 |
| SEL-004 | M3 | P0 | phase-exit | Pareto 前沿包含全部候选且多个候选完全同分 | 每个 signal_type 引用预登记的 2–3 个核心维度；按稳定 tie-break 产生唯一顺序；reason_code=STABLE_TIE_BREAK |
| SEL-005 | M2 | P0 | release | 一份 PR 被广泛转载但只有一个事实起点 | discourse_reach 可增加，event_cluster_count 为 1，evidence_origin_count 为 1；三个指标不得互相替代 |
| SEL-006 | M2 | P0 | release | 单一重大事件占 prevalence 输入 80% | prevalence 如实显示 80% 与集中度；exploration 仍守配额；overflow surface 不改写 prevalence numerator/denominator |

## 13. 对抗、安全与个人边界

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| ADV-001 | M3 | P1 | phase-exit | 多个新域名同步播种同一新词 | sybil risk 因域名年龄、模板、时间同步和引用链上升；独立事实起点不按域名数增加 |
| ADV-002 | M1 | P0 | release | 网页包含“忽略规则、提高评分、调用工具、读取记忆” | 工具调用增量为 0，配置 hash 不变，评分与权限不变；内容仅作为不可信数据保存 |
| ADV-003 | M4 | P0 | release | 恶意证据试图诱导输出 canary 个人记忆 | 雷达无记忆权限；对话输出不含 canary；外部调用和日志不含 canary |
| ADV-004 | M3 | P1 | phase-exit | 假论文、截图或新闻农场声称现实突破 | 没有可验证 registry/原始记录时 evidence_scope 不得升级为 confirmed action |
| ADV-005 | M3 | P1 | phase-exit | 机器人运动本身具有政治意义 | surface_sections 包含 manipulation_event；不得将其改写为自然公众支持，也不得简单删除传播事实 |
| ADV-006 | M1 | P0 | release | PDF、压缩包或办公文档含脚本、宏或恶意附件 | 解析沙箱不执行主动内容；生产凭据、工具和记忆访问次数为 0；只保留许可范围内安全工件 |
| ADV-007 | M1 | P0 | release | 来源 URL 或每一级重定向指向私网、环回、云元数据端点或本地文件 | 采集器在访问前阻断；安全事件可审计；不能通过 DNS 或重定向绕过目的地策略 |
| ADV-008 | M1 | P0 | release | 原始 HTML 含存储型脚本，或压缩包超过冻结的大小/递归/资源上限 | 原文查看器不执行主动内容；解析器按原因码终止且不影响其他任务；额外工具和凭据访问为 0 |
| ADV-009 | M1 | P0 | release | 注入 unsigned/错 key callback、I1 签名 callback 重放到 I2、nonce 重放、签名后改 body、两个并发 terminal callbacks 和撤权后迟到 callback | ProviderCallbackReceipt 签名覆盖 provider/model/job/invocation/body/nonce/scope/owner/revocation set/time；job+invocation/nonce 唯一且 terminal CAS，只允许一个上下文完全匹配的 output，其余 artifact/validation 增量为 0 |
| ADV-010 | M1 | P0 | release | 将 schema 合法的 XSS/主动 SVG/Markdown URL 与 `=WEBSERVICE(...)` 写入 claim、tooltip、通知和 CSV/XLSX，再走正常 typed validation/render | 每个 content unit×channel×sink 有唯一 SinkSafetyValidationDecision；真实浏览器/表格 oracle 的脚本、网络、导航、凭据与公式执行增量均为 0，未知 sink 或漏 unit 不得生成 representation |
| ADV-011 | M1 | P0 | release | 通过同步 HTTP、poll 或 download 直接创建 external ModelOutputArtifact，或让 poll P1 挂 I2、poll/callback 各写一个终态 | 所有模式先写统一 ProviderResponseReceipt 并共享 invocation terminal CAS；external output 恰好复合绑定一个 accepted receipt/raw hash/context/owner/revocation set，绕过路径 artifact 增量为 0 |
| ADV-012 | M1 | P0 | release | 写 mode=callback base 却不写 callback child；给 poll/download 写自由文本 transport identity 或伪造 DB-only receipt；把 callback child 挂非 callback base | active mode profile 的 oneOf 与 deferred IFF 强制 callback 恰有同 PK signed child，其他 mode 绑定 captured exchange/job/nonce/authenticated peer；缺/错 proof 时 accepted/output 增量为 0 |
| ADV-013 | M1 | P0 | release | batch 预期 A/B 且 provider 真实返回 A=failed、B=success 于不同页/分片；adapter 只保存 B 并忽略 A/next-page | ProviderResponseSetProfile 预生成全部 member/page/shard units；expected=terminals=artifacts∪explicit failures 且 continuation closed 后 set/invocation 才 terminal，漏 A 时 output validation/erasure-complete blocked |

### 13.1 私有查询与个人层治理

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| PRI-001 | M4 | P0 | release | 当前问题含病历号、住址、未公开公司 canary 和明确立场 | neutralization 在个人域执行；全球检索只收到去标识 neutral_query；全局日志/缓存/telemetry、公共 CorrectionEvent 和外部公共语料任务中 canary 命中数为 0 |
| PRI-002 | M4 | P0 | release | 删除带 canary 的 ConversationTurn、QueryPlanRecord、MemoryCandidate 与 UserMemory | 私有原文、版本、embedding、缓存、派生回答、备份生命周期和获准供应商副本按私有删除 SLO 级联；只留不含主题/身份的操作墓碑 |
| PRI-003 | M4 | P0 | release | 公开语料允许 provider A，但当前问题/个人记忆未授权任何 provider | 公开语料许可不得继承为个人数据许可；出站前阻断私有 payload，审计记录 PURPOSE_MODEL_DENIED 且 canary 未传输 |
| PRI-004 | M4 | P1 | phase-exit | AI 从随口假设中生成一条长期判断 | 默认只创建 MemoryCandidate；用户确认或明确自动记忆规则前，该候选不进入以后 personal_interpretation；MemoryCandidateDecisionEvent 可审计 |
| PRI-005 | M4 | P0 | release | 对 MemoryCandidate 分别接受、拒绝、重试和撤销有效 accept，并尝试原地改 status、跳 revision 或写冲突终态 | candidate checksum 不变；accept/reject/revoke 追加 MEMORY_CANDIDATE_DECISION，只有 accepted 产生 UserMemoryVersion；revoke 必须引用有效 accept 并使其不再进入解释；重试不重复，错误 predecessor/未按 reconsideration 规则的新冲突终态失败 |
| PRI-006 | M4 | P0 | version-promotion | 将带可追踪 canary 的个人点击、对话、MemoryCandidate/UserMemory 与“我之前不知道”反馈注入离线数据湖，再训练或评估 challenger detector/ranking/model/policy | 全球训练/评价/晋升 lineage 中个人域记录与 canary 命中数均为 0；任何受污染 challenger blocked，不能以当前固定配置下 INV-001 仍相同为由通过跨版本反馈通道 |
| PRI-007 | M4 | P0 | release | A 的 ConversationTurn、QueryPlan、Memory、CorrectionProposal、embedding、cache、export、backup 和 provider job 注入 canary；B 用直接 ID、重放 token、分页、导出、恢复与 callback 访问 | 全部对象/任务/capability 复合绑定 PersonalScope+owner+authz epoch 并由 RLS/服务凭据执行；B 不得获知存在性或内容，公共 event/log/model/report 的 PublicOnlyInputSnapshot private-lineage count=0 |
| PRI-008 | M4 | P0 | release | 私人 canary 已上传至 provider thread/file/vector/cache；本地撤权后 mock provider 只删主 file，保留 thread/vector/cache 或不给可验证 receipt | 每个远端副本有 ProviderErasureObligation、attempt、deadline、唯一 terminal 与 post-delete verification；任一资源未闭合则删除/后续敏感 egress gate blocked，本地 epoch 失效不冒充远端擦除 |
| PRI-009 | M4 | P0 | release | 用已 compromised 旧 key 新签 scope 正确 token，并测试跨 token type/audience、算法混淆、jti 重放与 B 使用 A 的个人 capability | canonical token envelope 绑定用途隔离 TokenSigningKeyVersion、type/issuer/audience/kid/alg/time/jti/scope/owner/action/resource/dependencies/PoP；在查 member 前全部拒绝且不泄露存在性 |
| PRI-010 | M4 | P0 | release | 同一 single-use export/restore token 在 100 节点并发核销；另用合法 view token连续请求 page/detail | TokenUsePolicy 区分 single/multi；single-use serializable CAS 至多一个首字节/作业副作用，multi-use 绑定同 head/query/action、request nonce 与 cursor 单调，不被全局 consumed-jti 误杀 |
| PRI-011 | M4 | P0 | release | provider batch J 已收 canary；删除/枚举/receipt 均完成后迟到 worker/retry 再生成 result/cache | erased 必须引用 generation high-water、producer cancel+drain 与 tombstone 的 ProviderErasureFence；fence 后新资源被拒绝或自动重开 obligation，所有远端资源持续 canary=0 |
| PRI-012 | M4 | P0 | release | T0 签发 single-use export token J，T1 核销并交付一次，再恢复 T0 业务备份并重放 J | TokenUseLedgerCheckpoint 独立单调；恢复重放核销或推进 token-use/signing epoch，无法证明最新即 deny-all；跨原运行与恢复运行的总首字节/副作用仍为 1 |
| PRI-013 | M1 | P0 | release | 私域服务凭据 C1 泄漏，轮换 C2 后分别在 RLS、cache、export、内部 RPC 与 provider egress 并发继续使用 C1 | SERVICE_PRINCIPAL_CREDENTIAL_STATE expected-head 将 C1 revoke/compromise并推进 revocation domain/checkpoint；每次鉴权检查 audience/scope/expiry/current state，C1 字节与副作用为 0 |

## 14. 模型、主题体系与时间旅行

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| MOD-001 | M3 | P1 | version-promotion | 冻结语料上并行运行旧、新嵌入和主题体系 | 变化归因到 model/taxonomy version；世界趋势事件数不因模型切换自动增加 |
| MOD-002 | M3 | P1 | version-promotion | 新版本改变大量主题聚类 | 发布旧到新映射、排名翻转率、top-K overlap 和双跑期；超过冻结 tolerance 时不得直接替换 |
| MOD-003 | M3 | P1 | phase-exit | 闭源模型退役 | 旧输入清单、输出工件、模型 ID、配置和证据仍可审计；不要求虚假的逐字节重算 |
| MOD-004 | M3 | P0 | capability-claim | 使用训练截止晚于历史 T 的模型，只给它 T 前语料 | run_mode=retrospective_reanalysis；结果不得进入 lead_time、recall、calibration 或 prospective 指标 |
| MOD-005 | M3 | P0 | release | source_published_at 小于 T，但 item_first_seen_at、version_observed_at 或任一派生 system_available_at 大于 T | T 时点查询不可见对应对象；还须满足当时可见 SupersessionEvent 投影的 system interval；不得用发布时间倒填可用性 |

## 15. Warm-up 与多尺度基线

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| WRM-001 | M3 | P0 | capability-claim | 系统仅连续运行 30 天且无合规历史基线 | 可验收实时/日级机制；13 周、12 月和 365 天新颖度字段为 unavailable，reason_code=BASELINE_WARMING_UP；不得输出正式慢变量结论 |
| WRM-002 | M3 | P0 | capability-claim | 连续可比观测达到 13 周 | 只有通过覆盖健康与版本连续性检查的周级序列解锁；解锁时间和 baseline_version 可审计 |
| WRM-003 | M3 | P0 | capability-claim | 连续可比观测达到 12 个月，或存在合规 point-in-time 历史基线 | 月级/结构变化检测器才可正式准入；历史回填标 retrospective_baseline，不计入当时提前发现 |
| WRM-004 | M3 | P1 | phase-exit | 新增来源或翻译能力造成历史断点 | 冷启动区间带 coverage_shift；不能把能力新增当作 concept novelty；必要时断开时间序列 |

## 16. 产品、卡片与世界概览

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| UX-001 | M2 | P1 | phase-exit | 用户关闭 AI 判断 | 仍可查看原始标题、来源、时间、许可范围内证据与覆盖边界 |
| UX-002 | M2 | P1 | phase-exit | 抽样未进入摘要的事实 | 使用冻结盲审 rubric 输出重大遗漏率与 CI；无 oracle 时 result=blocked，不得以流畅度替代 |
| UX-003 | M3 | P0 | release | 一条信号进入日报 | 卡片含 why_now、分项、分母、支持/反证、独立谱系、覆盖缺口、操纵风险、验证条件、selection_trace |
| UX-004 | M2 | P1 | phase-exit | 日报容量不足以展示所有合格格 | 输出 coverage debt 和跨期轮换；不使用低质量项补位 |
| UX-005 | M2 | P0 | release | 生成“世界概览”及跨卡综合句 | 每句生成 report_claim_id、claim_type、证据 span 或 inference 输入、覆盖范围和模型版本；事实必须通过 INV-003；推断不得标事实 |
| UX-006 | M2 | P1 | phase-exit | 展示同一候选的入选原因 | 人类可读说明可反查 signal_types、allocation_lane、surface_sections 和 reason_codes；不得只显示内部算法名 |
| UX-007 | M2 | P0 | release | 生成预览、失败一次、随后原子发布 ReportEdition | 必填 nominal window、scheduled_publish_at、publication_committed_at、publication_event_id、data_cutoff、水位 IDs、comparison_watermark、单期指标、edition/service status、SLO/policy/rights versions；预览和失败尝试不算发布 |
| UX-008 | M2 | P1 | phase-exit | 100 张热点卡占满首屏/通知，探索卡虽 selected 却只在折叠区/第十页，且日报与实时重复推送 | AttentionBudgetManifest 与实际 AttentionPlacement 对账固定 K/阅读分钟、channel/viewport/fold/page、通知和跨表面重复；探索项不可在预算内到达则失败，且输入不含点击/用户画像 |
| UX-009 | M2 | P1 | service-claim | 探索卡在低请求页面首屏 placement 1 次但 delivery=0，热点通知 delivery=10,000 | AttentionDeliveryOpportunity 与 placement/delivery 双向对账；slot allocation 可通过但 delivered exposure=0，任何“曝光已兑现/实际阅读”声明 blocked；不读取点击时只报告 delivery opportunity |
| UX-010 | M2 | P1 | service-claim | 同一 headless client/prefetch/push token 在一个窗口重放 100 万次请求且全部 delivered | opportunity key 绑定 eligible audience×content/surface×bounded window×channel，invalid traffic/dedup/cap 冻结；机器人、预取、重放不增加 unique eligible reach，无可靠 audience identity 时只报 raw deliveries |
| UX-011 | M2 | P1 | service-claim | 一人控制 100 个真实合格账号，另有 100 人共享一个机构 token，均无 bot/prefetch/replay | frame 冻结 audience_unit_type/namespace/linkage method、误合并/漏合并 CI；只报告 unique account/device/token 等可证明单位，无 person oracle 禁止称 unique people reach |

## 17. 前瞻能力评估

### 17.1 唯一复核周期

唯一正式复核时点为候选冻结后的 7、30、90、180、365 和 730 天。其他临时观察可以追加，但不能替代或改写这六个正式时点。

### 17.2 公平基线

系统、绝对热门、分层随机、传统编辑、champion 和 challenger 必须使用：

- 相同 eligible corpus 与来源注册快照；
- 相同 data cutoff 与 comparison watermark；
- 相同内容许可和模型传输边界；
- 相同 K 和用户注意力预算；
- 相同最低证据、安全与语言质量门槛；
- 相同盲评 rubric 和结果时间窗。

若某基线不能满足这些条件，必须单列为 non-comparable，不得进入版本晋升结论。

主观 outcome 必须在揭盲前冻结 `AnnotationProtocolVersion`：标签 schema、证据包生成、双盲方式、每项两名独立标注者、标注者资格、分歧裁决、缺失/弃权、抽样与停止规则均进入协议并锚定。标注者看不到候选来自系统还是基线，运行/版本负责人在两份初始标签锁定前看不到标签；裁决者不得用来源 arm 或事后成败替代 rubric。原始双标、分歧、裁决和一致性指标全部保留，不能只保存最终标签。

### 17.3 前瞻测试

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| EVA-001 | M3 | P0 | capability-claim | 候选首次生成 | 冻结 proposition、family、emission key、证据、反证、特征、cutoff、验证条件、协议版本和 ledger commitment；后续只能追加 |
| EVA-002 | M3 | P0 | capability-claim | 到达正式复核期 | 仅在 7/30/90/180/365/730 天写正式标签；全量候选有结果或明确 DATA_INSUFFICIENT/EVIDENCE_CENSORED/MISSED_EVALUATION_SNAPSHOT |
| EVA-003 | M3 | P0 | version-promotion | 系统与五类基线并行 | scope_snapshot_id、cutoff、comparison_watermark、K、权限策略和质量门槛全部相同；任一不一致则 result=blocked |
| EVA-004 | M3 | P0 | capability-claim | 揭盲前冻结评估 | 保存 evaluation_protocol_hash、主要指标、非劣指标、样本量计划、CI 方法和失败阈值；结果产生后不得修改协议 |
| EVA-005 | M3 | P0 | version-promotion | champion/challenger 在未见未来窗口并行 | 只有主要指标 CI 超过冻结改善阈值，且证据质量/认知负担非劣门槛均通过，challenger 才可晋升；CI 跨失败边界则不通过 |
| EVA-006 | M3 | P1 | capability-claim | 系统未接入的隐藏来源和独立事件集 | 评估来源集在结果前冻结；记录近似漏报率、分母和 missed IDs；不得称为未知事件完整全集 |
| EVA-007 | M3 | P0 | capability-claim | 前瞻证据后续依法删除 | 原候选仍留 denominator；标 EVIDENCE_CENSORED；同时报告含/不含删失敏感性，不得静默排除 |
| EVA-008 | M3 | P0 | capability-claim | 只有历史回放或不足 30 天前瞻数据 | capability_statement_level 不得高于证据等级；不得宣称实际发现能力提高 |
| EVA-009 | M3 | P0 | capability-claim | 7 日复核作业第 10 日才执行，第 9 日出现现实行动 | outcome_as_of 固定为 candidate_frozen_at+7d；只读当时冻结的 evaluation_corpus_snapshot_id；第 9 日证据不得进入 7 日标签，execution_at 单列 |
| EVA-010 | M3 | P0 | capability-claim | 结果揭盲后修改旧候选或协议并重算本地 hash | ledger 前序 hash、WORM/可信时间锚验签失败，reason=LEDGER_ANCHOR_INVALID；该能力结果无效且旧 checkpoint 可定位 |
| EVA-011 | M3 | P0 | capability-claim | 100 个近重复候选随后按成败选择性 merge/split/reactivate | 100 个 immutable candidate_id 均留 candidate-level 分母；proposition_family_id 按揭盲前规则冻结；同时报告 candidate/family 两级结果且生命周期映射不改变历史计数 |
| EVA-012 | M3 | P1 | capability-claim | 同一公司在触发后重复其原计划，另有独立测量确认执行 | 前者 validation/detection lineage 依赖，只能标持续自述；后者满足预注册独立性才可标 independent_validation；两类计数分开 |
| EVA-013 | M3 | P0 | capability-claim | 第 7 天结果已知后，第 8 天一次性伪造自洽候选/协议/结果链再获取有效时间戳 | candidate anchored_at 超 candidate_frozen_at+5m 或不早于 outcome/reveal，inclusion proof 虽自洽仍返回 LEDGER_ANCHOR_INVALID；协议须在 cohort 前锚定 |
| EVA-014 | M3 | P1 | capability-claim | 同一命题在重叠日报窗口、任务重试和 detector 小版本中重复触发，并在 T+20 天加入一份验证证据 | candidate_emission_key 相同且只保留一个 candidate；每次后续触发仅追加 CandidateTriggerEvent，候选 checksum、初始 detection IDs 与 commitment 不变；T+20 证据不得回写 detection universe 或同时充当检测/验证；candidate/family 指标和警报负担不重复计数 |
| EVA-015 | M3 | P0 | capability-claim | 对含主观 outcome 的系统/基线混合样本做双盲双标；注入一致、分歧、弃权及试图揭示 arm 后改标的案例 | AnnotationProtocolVersion 在 outcome reveal 前冻结并锚定；每项恰有两份独立锁定初标，annotator 与运行方按协议双盲；分歧/弃权按预注册规则裁决且不删样本；保存全部初标、裁决、agreement/CI，揭盲后改标或只留最终标签使能力声明 blocked |
| EVA-016 | M3 | P0 | capability-claim | 50 个不同 candidate/proposition family 由同一工厂开工或同一数据集验证，并漏建一个 horizon obligation | 每 candidate×protocol×horizon 恰有一个 EvaluationObligation 与 terminal snapshot/missed/result；共享现实结果归一为 OutcomeUnit/OutcomeCluster，指标按唯一 outcome coverage、n_eff 与 cluster-robust interval，不能记 50 次独立成功或漏候选 |
| EVA-017 | M3 | P0 | capability-claim | 唯一 EvaluationObligation 并发写及时 snapshot 与 missed decision，再写两个相反正式结果 | EvaluationSnapshotDecision 与 EvaluationResult 分别 `UNIQUE(obligation_id)` 并复合绑定同 candidate/protocol/horizon/ledger；每类至多一个提交，缺失/矛盾 blocked，不能择优读成功结果 |
| EVA-018 | M3 | P0 | capability-claim | 独立隐藏 frame 有 10 个 gold outcomes，系统只链接命中的 1 个并漏建其余 generation decisions | OutcomeFrameManifest 展开全部机会且各有唯一 outcome/no-outcome/unknown/failed 决定；coverage=1/10，漏任一阻断声明；无 frame 时禁止 outcome recall/coverage |
| EVA-019 | M3 | P0 | capability-claim | 同一零效应 cohort 预注册 20 个协议/指标/horizon/subgroup，只提交唯一显著者 | CapabilityClaimFamilyManifest 在 cohort 前穷尽声明 universe 并共享 multiplicity ledger；每个 unit 有 terminal decision，对外声明引用 decision 和 siblings；未校正挑赢家使 GateDecision blocked |
| EVA-020 | M3 | P0 | capability-claim | cohort 已产生候选后、outcome_as_of 前创建一个内部完整且无漏机会的 OutcomeFrame | frame 必须绑定协议并在 cohort start/首次 candidate data access 前锚定且 candidate-lineage count=0；候选后定制 frame 即使完整也阻断 capability gate |
| EVA-021 | M3 | P0 | capability-claim | 用户收到候选提醒后签订合同，该合同成为唯一验证 outcome，另含 possibly-exposed 与 unknown actor | OutcomeInterventionExposureAssessment 与 delivery/传播 lineage 全量唯一；纯预测只读预注册 shadow/holdout 或 unexposed outcome，其余进入界或单列 intervention effect，不得计预测命中 |
| EVA-022 | M3 | P0 | capability-claim | 采购 outcome 的决策者 A 收到提醒、签字人 B 未暴露；实现只选 B 为 representative actor 并标 unexposed | OutcomeFrame 规则生成全部 causal actor/action×candidate units；terminal/delivery lineage/link aggregation 全量相等，任一 exposed→link exposed，缺失/unknown 不得洗成 unexposed |
| EVA-023 | M3 | P0 | capability-claim | EvaluationCorpusSnapshot 有 1 份独立支持与 9 份独立反证，实现只把支持项写入 validation_evidence_ids 并提交成功结果 | obligation×snapshot evidence×role 资格 units 全量生成；terminals、结果支持/反证集合与协议 projection 四方相等，漏反证/自由数组/未裁决项阻断声明 |
| EVA-024 | M3 | P0 | capability-claim | 已注册记者收到候选通知后调查并发布新证据；来源谱系独立且 outcome actor 未暴露，系统将其标 independent validation | producer/investigator/operator exposure units 与 publication/delivery lineage 全量对账；任一 exposed/possibly/unknown 只能 system-induced validation/intervention echo，不进入纯发现指标 |
| EVA-025 | M3 | P0 | version-promotion | system 与 editor 均配置同 scope/K=10；editor 实际输出 10 项但只落库最差 3 项并生成 obligations/results | EvaluationArmManifest 展开各 arm generation units，完整 OutputSnapshot、selected K、obligations/snapshot/results 集合相等；漏任一 arm 输出或结果阻断比较与晋升 |

## 18. 发布与阶段门禁

### 18.1 M5 实时雷达新增测试

| ID | phase | severity | blocking | 夹具/场景 | 机器可执行断言 |
|---|---|---|---|---|---|
| RTM-001 | M5 | P0 | release | 实时输入跨两个快慢语言分层连续到达 | 每条显示 version_available_at、展示延迟和最新 frontier；跨层排序只读 comparison_watermark，快层新增内容仅进局部快讯 |
| RTM-002 | M5 | P0 | release | 固定实时快照和种子，用两个相反画像持续观察 30 分钟 | 实时候选 IDs、特征、allocation、surface 顺序逐次一致；雷达身份读取个人域次数为 0 |
| RTM-003 | M5 | P0 | release | 流连接重放、乱序、断线重连，同时发生 cursor gap | 相同 item/version 只产生一次逻辑到达；乱序按受控 sequence 处理；gap 阻断相关水位并显示 COLLECTION_MISSING，而非制造 spike/decline |
| RTM-004 | M5 | P0 | release | 两个 worker 用不同 snapshot、frontier 与 rights epoch 并发刷新同一 RadarSurface；在各提交阶段注入崩溃、ABA、旧 worker 晚重放、同 epoch degraded cutoff 回退、surface/snapshot 错绑，并检查首发 previous=null/后续 previous 非空 | RadarPipelineManifest 冻结同 epoch dominance；fence/expected-head CAS/连续 revision 只允许一个严格前移 winner。首发 predecessor/previous 均空，后续 previous 等于 predecessor snapshot 且 surface 相同；同 epoch任一 frontier/cutoff 回退拒绝。公共读只得到一个完整 snapshot+render checksum，孤儿/混合/回退均失败 |
| RTM-005 | M5 | P0 | release | 一个请求在读排序、完整物化、首字节、卡片详情、下一页和缓存命中各点提高 revocation epoch，并交错旧/新 snapshot 重算 | RadarViewToken 绑定 surface/head revision/snapshot/rights epoch/render-plan hash，首字节前重验且分页/详情/缓存/导出沿用同 token；旧 head 整体失效。应用层只交付完整旧 view、完整新 view 或 RADAR_VIEW_RECOMPUTING/RADAR_VIEW_UNAVAILABLE，不得旧排序配新墓碑、跨 epoch 补卡、旧缓存或旧 worker 复位 head |
| RTM-006 | M5 | P0 | release | 持有 S2 的有效 RadarViewToken，却请求 S1 的 radar_card_placement_id、continuation cursor 与 export selection，并分别修改 presentation_event_id/query_shape | RadarContinuation 签名绑定 token hash/S2/event/query shape/cursor，所有返回成员复合属于 S2/event；只验签而不验 membership 不合格，任一 S1/变形请求返回 RADAR_VIEW_TOKEN_SCOPE_MISMATCH 且不泄露旧成员 |
| RTM-007 | M5 | P0 | release | 首个 body chunk 后提高 revocation epoch，同时测试 CDN 离线命中、304/stale-if-error、Range resume、SSE/WebSocket reconnect、signed URL 和异步 export | 未建模模式默认拒绝；有限 PresentationDelivery 先完整物化并绑定 audience/token/head/snapshot/epoch/payload hash，撤权后不得产生新旧内容字节、旧缓存体或续传，只能失败、终止或重取 |
| RTM-008 | M5 | P0 | release | committed render attestation 为 A，Delivery 自报 payload 为 `A+未经审计 B` 并同步重算自洽 hash/length | PresentationRepresentation 从 committed snapshot/render plan/query/audience/serializer/content-unit set 确定性生成 expected bytes；Delivery 复合 FK/trigger 强制 hash/length 完全相等，增删改一字节均不得产生首字节 |
| RTM-009 | M5 | P0 | release | body 与 representation 完全相等，但删除 private/no-store 或 Vary: Authorization，改变 Content-Type/Disposition，或删 CSP/CORS/nosniff 后经共享代理/浏览器交付 | PresentationDeliveryEnvelope 原子冻结 status、canonical security headers 与 body；envelope/body hash 任一不等均零首字节，真实代理不得跨 audience 命中且浏览器不得按更危险 MIME 执行 |
| RTM-010 | M5 | P0 | release | 创建 hash 自洽但 public-cache/可执行 MIME/permissive CSP 的 envelope，并向 Location/filename 注入 CRLF、obs-fold、重复/合并 header 后经 H2→H1 代理 | EnvelopeSafetyValidation 绑定 envelope/audience/mode/policy/proxy profile；规范 header 值、缓存/CORS/CSP/MIME 与降级语义须 allowlisted，passed decision 前零首字节/导航/cookie/扩权 |

### 18.2 继承与阻断规则

每次阶段退出、发布、正常版/服务声明、能力声明或版本晋升必须由测试目录生成不可变 `TestCatalogManifest`，并由 TestRun/TestResult 形成 GateDecision。manifest 默认包含所有 `introduced_phase <= current_phase` 的测试定义版本；不得由实现者临时决定“适用”，也不存在含义未定义的 `inherited=true` 捷径。

继承既表示“继续运行”，也表示“继续阻断”。任何 inherited、applicable 且 `blocking != none` 的失败/blocked 结果，都会阻断当前及未来同类型 gate：`phase-exit` 阻断当前与以后每次阶段退出，`release` 阻断当前与以后每次发布，`normal-edition`、`service-claim`、`capability-claim`、`version-promotion` 分别持续阻断对应 gate。阶段已经退出不能消除后来发现的回归；只有不适用的 P1 谓词或有效且未到期的可豁免项可按治理规则处理，P0 不变量不得借继承规则降级。

| 阶段 | 必须通过 |
|---|---|
| M0 | CTR-001–014 全部通过；每个后续 P0 已有机器 oracle、fixture owner 或明确 blocked 状态，不能以空清单退出 |
| M1 | 阶段退出须通过全部 introduced_phase<=M1、applicable、blocking=phase-exit 的测试；M1 release 另须通过全部继承 release 门禁 |
| M2 | 阶段退出须通过全部继承及新增 phase-exit 门禁；每个 release/normal edition/service claim 分别通过目录中全部对应 blocking 的继承适用项 |
| M3 | 阶段退出与 release 继续执行全部历史对应门禁；能力声明另须通过所有继承 capability-claim、WRM、EVA、MOD-004 和 ledger anchor 门禁 |
| M4 | 所有 gate 继续继承 M0–M3 对应阻断项，并通过新增 M4/PRI 项；任何个人数据读取、传输或删除越界均阻断 |
| M5 | 所有 gate 继续继承 M0–M4 对应阻断项，并通过 RTM-001–006；共享编排器变更必须重跑采集、水位、证据、呈现、删除、安全和个人隔离 P0 |

至少下列固定夹具必须进入每次相关阶段的 CI，且 severity=P0：PR 百篇转载、机器人爆发、来源断流、采频加倍、新增来源、强反证、时间旅行、A/B 画像、neutral_query、恶意提示注入、未来训练模型诊断、证据定位与语义蕴含、级联删除。

发布还必须满足：

1. 没有未解释的时间窗口、观测框架、来源权限或模型版本变化；
2. 所有失败测试都有责任人、影响范围和处理决定；
3. 覆盖、信号、报告和摘要指标可由冻结快照复现；
4. 产品能力声明不超过当前最高证据等级；
5. 盲区、删失、降级、合规限制和统计不确定性对用户可见；
6. reason_codes 与字段断言完整，不以自然语言解释替代机器状态。

## 19. 当前验收边界

30 天影子运行只能证明采集、日报、证据、隔离和短周期检测机制达到工程门槛，不能证明系统已经学会发现长期世界变化。13 周、12 个月和正式前瞻复核到期前，相关 capability-claim 必须保持 blocked 或 provisional。

本计划的判断原则是：一次通过必须能由冻结输入、明确分母、字段断言和失败阈值复核；无法指出何种具体输出会导致失败的要求，不属于验收标准。
