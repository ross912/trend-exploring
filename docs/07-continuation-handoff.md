# 设计续跑交接

- 更新时间：2026-08-07
- 当前状态：**M0 已于 2026-08-05 有条件冻结，进入 M1 实施**
- 停止规则：旧的连续三轮规则已由用户终止；Round 16 作为最终有界审查，6 个已知实施阻断项修复后冻结。后续问题进入 M1 backlog，只有数据破坏、越权或正式能力声明错误才重开 M0

## 1. 用户目标

构建一个不被用户既有兴趣驱动的个人全球变化雷达：保留许可范围内的原始世界记录，在全球、多语言、多社会角色的可观察来源中同时展示热点与弱信号，尤其寻找讨论、行动和跨圈层扩散的早期变化；个人记忆只参与第二阶段对话解释，绝不反馈到采集、候选生成、排序或全球报告。

不能承诺“覆盖全部世界”“没有任何权重”或“预测真正的黑天鹅”。可验证目标是：扩大覆盖与新颖度，公开观测边界和系统分配规则，并以前瞻台账衡量早期信号能力。

## 2. 已确认边界

- 每日北京时间 08:00 与 19:00 两个计划报告时点；报告必须公开实际 data cutoff、水位、迟到和降级。
- 热点、弱信号、跨圈扩散、衰退和探索并存；流行度视图与探索曝光不能混成一个总分。
- 原始资料与版本在合法范围内追加保存；AI 摘要、结构化、信号和重分析均为可追溯派生层。
- 当前问题、query plan、对话和长期记忆属于个人域；neutralization 在个人域完成，全球检索只接收临时去标识查询。
- 允许较多早期误报，但不得删失败样本或通过后验合并美化结果。
- 现代模型对历史资料的重分析只能作诊断；正式发现能力依赖规则冻结后的真实前瞻数据。

## 3. 当前文档职责

- `00-requirements-and-implementation-roadmap.md`：需求、边界、产品表面和 M0–M5 路线。
- `01-global-information-coverage-matrix.md`：目标来源宇宙、分层覆盖、采集机会、权限集合、曝光预算和语言可行性。
- `02-weak-signal-specification.md`：弱信号检测、证据、生命周期、候选发射和前瞻评估。
- `03-design-review-log.md`：每轮新增失败类别、修复和连续无新增计数。
- `04-acceptance-test-plan.md`：机器可失败的规范测试与阶段继承门禁。
- `05-canonical-data-and-time-contract.md`：对象、ID、双时间、权限、状态、报告和保存语义的最高权威。
- 本文：只记录续跑状态，不另造业务语义。

## 4. 当前审查状态

- Round 10 的身份、时间、终态、rights、watermark 与候选冻结问题已同步，历史记录见 03 第 13 节。
- Round 11 已完成本地审查及三名实际完成的独立 reviewer。最初尝试的运营/统计/隐私三路因账户额度在读取前失败，不能算审查。实际 reviewer 发现了新的 P0/P1，因此连续计数仍为 `0/3`。
- Round 11 新增的主要控制：ReportCardPlacement；ClaimGenerationUnit/Decision 的 min/max ordinal；ReportClaim/ClaimExpressionVariant/ClaimCitation；每 event 唯一、kind-specific typed PresentationRenderPlan/PresentationContentUnit；initial/amendment 的 ComposedPresentationSnapshot/ReportViewToken；RadarSurface/RadarPipelineManifest/GlobalRadarSnapshot/RADAR_PUBLICATION current-head；RadarViewToken/RadarContinuation；撤权 epoch 整体失效；完整 EventStateDefinition/TransitionDefinition 与 EventApiAlias。
- Round 11 修复的失败类别包括：零 claim/自由文本旁路、空态模板冒充、跨 locale/ARIA 语义漂移、无关来源冒充证据、amendment 读时拼裂、实时 head 回退/跨 epoch 撕裂、token 成员越界、claim cardinality 无法生成、render 裸多态、RADAR 首发 previous 矛盾、cutoff 回退冲突、状态机和 API alias 不可编译。详见 03 第 14 节。
- Round 12 的 SQL/事务、安全/运营、产品/统计三名独立 reviewer 均已完成，共发现 9 个 P0 与 2 个 P1；连续计数仍为 `0/3`。新增类别是 CoverageItem 同义复制、EventCausalParent 非 DAG、租户所有权、模型 egress/tainted output、CDN/Range/stream 撤权、备份回滚、连续检验重置、candidate 条件化来源招募、共享 outcome 虚增、selected 不等于注意力曝光、detector 前 OOD 丢失。详见 03 第 15 节。
- Round 12 修订已按 05→00/01/02→04 同步：Coverage projection UUIDv5、不可变因果 DAG、PersonalScope/PublicOnlyInputSnapshot、ModelTask/OutboundPayload/Invocation/Validation、DeliveryPolicy/PresentationDelivery、ComplianceRevocationLedgerCheckpoint/RecoveryFence、SequentialHypothesis ledger、RecruitmentCohort、OutcomeUnit/Cluster、AttentionPlacement 与 PreDetectionExploration。
- Round 13 的 schema/DDL、安全/恢复、统计/产品三名独立 reviewer 均发现新类别，去重后为 10 个 P0 与 2 个 P1；连续计数仍为 `0/3`。新增控制覆盖：评分前 test opportunity/root alpha、跨 candidate conditioning closure、探索 eligibility 分母、AttentionDeliveryOpportunity、独立 OutcomeFrame、CapabilityClaimFamily、评价 snapshot/result 唯一终态、模型 validation unit、committed representation→delivery、签名 callback、provider effective context 与复合撤权依赖。详见 03 第 16 节。
- Round 14 的三名独立 reviewer 又确认 12 个 P0 与 2 个 P1，连续计数仍为 `0/3`。新增控制覆盖：online procedure 可预测顺序/阈值、来源发现机会框、OutcomeFrame cohort 前独立性、系统输出干预污染、合格受众去重、完整交付 envelope、sink 安全、统一 provider response receipt、远端 erasure 状态机、token signing lifecycle、authority epoch 防回滚根、manifest 激活 CAS、snapshot typed membership 与 gate run closure。详见 03 第 17 节。
- Round 15 的 compiler、协议安全、统计反事实 reviewer 共确认 9 个 P0 与 2 个 P1，连续计数仍为 `0/3`。新增控制覆盖：provider ingress mode totality/authenticity、async invocation FK 方向、token use/consumption、envelope policy/header safety、snapshot current profile、erasure generation fence、online authority lease fencing、conditional p/e validity、source discovery program frame 分母、outcome actor exposure 与明确 audience unit。详见 03 第 18 节。
- Round 16 是用户指定的最终有界审查，确认并修复 6 个 P0：provider response member closure、TokenUse 恢复防回滚、ServicePrincipalCredential lifecycle、validation evidence 资格分母、validation producer 暴露与 evaluation arm 输出分母。详见 03 第 19 节。
- 当前静态结果：04 有 233 个唯一测试 ID且无重复；05 有 169 个 immutable records 与 36 个 manifests，time-profile 双向 missing/extra/duplicate 均为 0；02 的 6 个 JSON blocks 全部可解析；全部 Markdown 表宽和 code-fence parity 通过。
- M1 首批 PostgreSQL 15.18 实现已在临时本地集群完成真实 parser/transaction 执行：迁移、25 表 append-only catalog smoke、pgcrypto/btree_gist 均通过。
- M0 已有条件冻结；旧连续计数停在 `0/3`，不再继续 Round 17。下一步是 M1 可执行 schema 与最小垂直切片。

## 5. 下一步顺序

1. 从 05 生成首批可编译 PostgreSQL DDL 与 JSON Schema，先覆盖 identity/record registry、manifest activation、provider response set、token use、credential lifecycle 与 evaluation arm closure。
2. 建立 schema validator 和最小反例 fixtures，优先物化 CTR-017–020、ADV-011–013、PRI-010–013、EVA-023–025。
3. 完成一个 M1 垂直切片：冻结输入→生成 obligation/unit→唯一 terminal decision→gate，并保留所有 immutable lineage。
4. 实现问题进入 implementation backlog；除非触发数据破坏、越权或正式能力声明错误，不重新启动全面规范审查。

## 6. 建议复核命令

```bash
rg -n --pcre2 "(?<!item_)first_seen_at|version_first_seen_at|DocumentVersion|document_version_id|O_model_local|O_model_external|edition_status=failed|normal\\|degraded\\|failed|reportability_decision|causal_parent_ids|expected_update_cadence|last_verified_at|test_governance_policy_id|AnnotationProtocolManifest|待创建" README.md docs/*.md

awk -F'|' '/^\| [A-Z][A-Z0-9]*-[0-9]/{id=$2; gsub(/^ +| +$/, "", id); print id}' docs/04-acceptance-test-plan.md | sort | uniq -d

awk -F'|' '/^\| [A-Z][A-Z0-9]*-[0-9]/{print NF ":" NR ":" $0}' docs/04-acceptance-test-plan.md | awk -F: '$1 != 8'

rg -n '^```' docs/*.md
git status --short
```

另用 JSON 解析器校验 02 中所有 `json` code blocks，并对 05 的 immutable_record 与 raw/bitemporal/snapshot/derived/operational time profiles 做双向集合对账。若任何检查失败，不能增加连续无新增计数。

## 7. 交接禁忌

- 不得声称设计“完美”；最多声称达到了预注册停止规则。
- 不得把 failed slot 表达为 failed ReportEdition；失败时没有 PublicationEvent/ReportEdition。
- 不得回写不可变 Version 的权威 `system_to/valid_to`；它们是 EventBase 的 as-of 投影。
- 不得把来源因果主张当作现实因果，也不得让 AI 因果推断绕过 premise gate。
- 不得让用户记忆、点击或当前立场进入全球候选、排序或报告。
- 不得用今天的新模型历史回放证明当时已提前发现。
- 不得把推理许可解释为训练许可；训练资格默认 false。
- 不得让 metadata-only 或 external-pointer 工件声称可恢复未保存的正文。
- 不得因删除证据、合并候选或漏建报告行而缩小评价/SLO 分母。
- 不得根据 `*Version/*Snapshot` 后缀自动添加 parent 或双时间字段；必须逐对象读取 05 的 archetype registry。
- 不得让 `eligible_*` 布尔投影替代 grant/scope/processor/transform/retention/epoch 的逐次授权。
- 不得让 detector 零运行以空集合真空通过完整性门禁，也不得让不同 worker 对一个 slot 发布两份初始版。
- 不得让 candidate_count=0 以静态模板冒充世界空态；必须有绑定 completeness/watermark/coverage/rights/观测状态的 empty-state claim。
- 不得让客户端临时翻译或 ARIA/通知文本改变否定、模态、数值、来源归属或 AI 推断标记；必须使用 ClaimExpressionVariant。
- 不得把合法但无关的来源标题/引文邻接为证据；必须使用 ClaimCitation 和正确 citation role。
- 不得在读时拼 ReportEdition base 与 amendment deltas；当前 view 只读一个 ComposedPresentationSnapshot head。
- 不得把预览/孤儿 GlobalRadarSnapshot 当 current，也不得让同 epoch frontier/cutoff 回退或旧 epoch worker 复位 RADAR_SURFACE_HEAD。
- 不得只验证 RadarViewToken 签名而不验证 card/cursor/export 是否属于 token 的 snapshot、presentation event 与 query shape。
- 不得让 event from/to 只靠自然语言；必须命中签名 EventStateTransitionDefinition/typed guard，所有 typed API ID alias 等于同一 EventBase.event_id。
- 不得让个人反馈通过训练、离线评价或 champion/challenger 晋升间接改变全球配置。
- 不得回写候选的初始 detection universe；后续 evidence/detector 只能进入 CandidateTriggerEvent。
- 不得用稳定 stratum ID 代替具体版本水位，也不得在矛盾双终态或 open WatermarkGap 上推进 frontier。

## 8. M1 当前进度与 backlog

已完成首批 PostgreSQL DDL、ProviderResponseSet JSON Schema、正反 fixtures、Ruby semantic validator 和本地测试。response set 采用同一 canonical identity 的两阶段物化：invocation 前冻结主表，最后写无第二身份的 closure child。

2026-08-05 的首轮 M0/M1 综合自检已完成：统一验证器对账 233 个验收 ID、41/169/36 canonical archetype、time profiles、JSON/Markdown、object map 与 Schema/Ruby 字段；并修复 response set closure 与晚追加并发窗口。云端 PostgreSQL 预检及空测试库 migration smoke 入口已经准备，但尚未获得 SSH 访问并实际执行。

下一步：

- 使用 `schema/postgres/test/002_m1_transaction_fixtures.sh` 在明确 disposable 的 PostgreSQL 15+ 数据库中重复运行 ADV-013、PRI-012–013、EVA-025 的事务、恢复 epoch、并发序列化和集合闭合测试。
- 将已通过的 PostgreSQL fixtures 接入 TestDefinition/TestRun/TestResult 物化层，并补充其他 M1/M4 数据库闭合约束。
- 生成权限矩阵、EventBase 状态机、双时间查询模板和 identifier linter。
- 证明 P0 applicability 永远 fail closed。
- 执行小规模来源、许可、语言、成本和恢复可行性试验。

不要恢复旧 `3/3` 审查循环。实现中发现的一般问题进入 backlog；只有数据破坏、越权或正式能力声明错误才重开 M0。
