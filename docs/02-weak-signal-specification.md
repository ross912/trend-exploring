# 弱信号定义与评分规范

- 文档版本：v0.1-m0-baseline
- 状态：M0 有条件冻结的实施基线；M1 实施中
- 适用范围：全球信息采集后的候选发现、信号分析、日报与实时雷达展示、历史回测
- 核心目标：优先扩大覆盖广度与认知新颖度，允许早期误报，但要求误报可解释、可追踪、可复盘

## 1. 目的与边界

本规范定义系统如何从全球信息流中发现“世界可能正在变化”的早期迹象，并将其转化为可追溯、可比较、可持续观察的弱信号。

系统不声称预测黑天鹅，也不输出“未来一定会发生什么”。系统回答的是：

1. 哪些过去罕见或不存在的现象开始出现；
2. 哪些现象的讨论、行动或扩散方式正在发生异常变化；
3. 这些变化由什么原始证据支持，又有哪些反证；
4. 下一步观察到什么，才会增强、削弱或证伪当前判断。

本规范采用以下强制语义：

- **必须**：v0.1 上线前不可省略；
- **应该**：除非有记录在案的技术原因，否则应实现；
- **可以**：增强能力，不构成首版阻塞项。

### 1.1 非目标

- 不建立一个根据用户兴趣优化点击率的推荐系统；
- 不以单一总分决定“什么最重要”；
- 不把讨论量等同于现实变化；
- 不把多个转载页面误认为多份独立证据；
- 不将模型推断写成事实；
- 不因表现不佳而删除后来消退或被证伪的信号；合法删除和隐私义务除外；
- 不用个人记忆、个人点击或个人观点改变全球雷达的采集、候选生成和排序。

## 2. 核心定义与分析单位

### 2.1 规范对象链

数据链路必须使用以下规范对象，不得用“文档”“事件”“来源”和“证据”互相代替：

| 对象 | 定义 | 关键边界 |
|---|---|---|
| 捕获 `capture` | 对一个来源端点与计划采集机会执行的一次请求或读取尝试 | 成功、空结果、失败、限流和隔离都要留状态；不能把“未抓到”当作来源没有内容 |
| 原始载荷 `raw_artifact` | 一次捕获中按许可保存的 payload、文件、片段或元数据指针 | 不强制保存全文；受许可、隐私与删除控制 |
| 原始条目 `raw_item` | 来源侧稳定内容身份，例如一篇文章、公告或帖子 | 使用稳定 `item_id`，一个条目可以有多个版本 |
| 原始条目版本 `raw_item_version` | 某次捕获观察到的具体内容版本 | 使用 `item_version_id`，追加保存或按政策投影为墓碑，不被后续版本覆盖 |
| 来源端点 `source_endpoint` / `source_endpoint_version` | 稳定访问端点身份及某一系统时点可用的 URL、协议、法域和描述性 `source_declared_update_cadence` | 描述节奏、地址或协议变化只追加 Version；执行性分母只读取 CollectionPlanManifest.`planned_poll_cadence`，端点不等于发布者 |
| 内容游标 `content_cursor` / `content_cursor_checkpoint` | 稳定增量读取身份及一次不可变的分页 token、时间水位或序号检查点 | 捕获只引用 `cursor_checkpoint_id`；推进、回退或重建均追加 checkpoint，并保存 `previous_cursor_checkpoint_id`、transition reason 与受控 sequence，不覆盖“当前游标”字段 |
| 规范条目 `canonical_item` | 对获准的 `raw_item_version` 做格式标准化、语言识别和精确/近似去重后的可分析版本 | 清洗和抽取均为派生物，不能覆盖原始条目或版本 |
| 翻译工件 `translation_artifact` / `translation_artifact_version` | 稳定翻译任务身份及一次不可变的源版本、目标语言、模型和译文快照 | 保存 `translation_artifact_version_id`；新模型或人工修订只追加 Version，不能覆盖旧译文或伪装成原文 |
| 发布账号 `publisher_account` / `publisher_account_version` | 稳定发布者/账号身份及某一系统时点可用的名称、来源类型、社会角色、地区、平台状态与所有权引用 | `publisher_account_id` 不随重命名或重分类改变；角色、地区或所有权变化只追加 Version，特征不得读取当前画像 |
| 所有权集团 `owner_group` / `owner_group_version` | 稳定控制集团身份及某一系统时点可用的控制关系、成员和母子集团快照 | 收购、拆分和控制关系修订只追加 Version；未知所有权显式为 unknown，不能用未来发现回填历史运行 |
| 来源注册表快照 `source_registry_snapshot` | 某个 `as_of` 可见的端点—发布账号—所有权映射、角色/地区分类、描述节奏、执行计划及权利快照引用的内容寻址清单 | 必须物化具体 `endpoint_version_id`、`publisher_account_version_id`、`owner_group_version_id`、`rights_snapshot_id` 与 `collection_plan_id`；描述字段只用 `source_declared_update_cadence`，执行分母只用计划 manifest 的 `planned_poll_cadence` |
| 权利依据 `rights_grant` / `rights_grant_version` | 稳定授权依据及一次不可变、可撤销的法源、用途、法域和期限决定 | 后续收窄或撤回只追加 `rights_grant_version_id` 与 typed rights event，不改旧 grant version |
| 授权内容范围 `authorized_content_scope` | 某资源版本获准处理的字段、byte/span、最大展示量、处理方、transform、derivative type 与 retention | `PurposeAuthorization` 必须引用 `authorized_content_scope_id`；不得用定位命题证据的 EvidenceScope 代替法律/许可范围 |
| 来源谱系 `source_lineage` | 共同源自同一原稿、新闻稿、通讯社稿、原帖或协调分发起点的一组规范条目 | 描述传播依赖，不等于独立事实证据 |
| 事件簇 `event_cluster` | 指向同一现实事件的一组规范条目 | 一个事件簇不是一条已确认事实；非事件型输入不强行归入事件簇 |
| 独立证据单元 `evidence_unit` | 在观察、数据生成或一手记录上具有同一事实起点的一组材料 | 一份公告及其转载通常是一个证据单元；不同独立测量可形成多个单元 |
| 主张关系 `claim_relation` / `claim_relation_version` | 稳定关系身份及某一系统时点可用的来源主张、观察关联或因果假设快照 | 版本保存主体、否定、限定、断言类型和证据范围；关系变化只追加新版本 |
| 行动 `actor_action` / `actor_action_version` | 可去重的稳定行动身份及意向、承诺、执行、取消或结果快照 | 阶段变化生成新 `action_version_id`，同一行动的转载不得升级阶段 |
| 观察 `observation` / `observation_version` | 稳定观察身份及由证据单元支持的结构化陈述、测量值或时间序列切片 | 版本必须包含分母、范围、时间、断言类型和证据关系；缺失不能伪装成零 |
| 修订评估 `revision_assessment` / `revision_assessment_version` | 对不可变 `raw_item_version` 差异类型与可报告性的追加式判断 | 同一不可变版本保存 `revision_type`、`reportability`、输入 diff、规则/模型、理由和 `decision_system_available_at`；重分类只追加 Version 与 SupersessionEvent，不修改原始版本或旧判断 |
| 覆盖分层 `coverage_stratum` / `coverage_stratum_version` | 稳定比较分层身份及某一 system as-of 的地区、语言、媒介、角色、领域状态和纳入谓词 | 分类边界修订只追加 Version；水位、分母、特征和历史报告都引用当时的 `stratum_version_id` |
| 覆盖计数项 `coverage_item` | 对事件或非事件输入形成的 L2/L3 稳定计数投影 | `kind` 必须来自 `signal_input_union`；规范 projection key+UUIDv5+唯一键防止同义复制膨胀覆盖/生成分母 |
| 候选生成单元 `candidate_generation_unit` | 对一个冻结 scope/pipeline key 下的 eligible CoverageItem × 具体 DetectorVersion 的确定性义务 | 先物化 `generation_unit_id` 再运行；实际 worker 输出不能反向决定分母 |
| 候选生成决定 `candidate_generation_decision` | 对一个 CandidateGenerationUnit 的 candidate/no-candidate/failed 终局判断 | `UNIQUE(generation_unit_id)`；无候选也保存输入和理由，缺行不是“没有信号” |
| 信号候选 `signal_candidate` | 检测器产生并首次冻结的可证伪变化命题及其触发记录 | `candidate_id` 与预注册 `proposition_family_id` 不可变；可关联多个覆盖项，但须指定主项、主格和唯一 `allocation_lane` |
| 信号 `signal` | 具有稳定 ID、版本与生命周期的变化命题 | 关联观察、基线、支持、反证和后续验证条件 |
| 候选选择单元/决定 `candidate_selection_unit` / `selection_decision` | 冻结 selection scope/run、candidate、surface 与 allocation context 后的一次选择义务及唯一终态 | 先物化 `selection_unit_id`；`UNIQUE(selection_unit_id)`，未选和失败同样留决定，不能只存入选项 |
| detector 前资格/探索单元与决定 | 对每个 CoverageItem 的资格终态、合格 unknown/OOD 的用户无关随机探索义务及唯一终态 | 不能先看内容只为赢家建 unit；selected 只能显示为 `not_a_signal=true` 的未解释材料 |
| 来源发现 program/frame/机会/决定、招募/条件闭包 | program 先冻结应运行的地区×语言×渠道/query frame 分母，frame 再冻结该渠道返回的全部来源候选，以及 candidate/family/query→source→后继 candidate 因果闭包 | program frame opportunities=run/skipped/failed terminals 且 run 一对一引用 frame；frame source opportunities=terminal decisions；不能选择性只建容易 frame，candidate-conditioned 来源也不能跨 candidate/family 洗白扩散或确认 |
| 检验 universe/机会/输入快照/family/账本 | 所有被评分机会、全局 alpha 父预算、统计量可见前冻结的逻辑顺序/阈值承诺、每项 TestStatisticInputSnapshot、filtration/dependence lineage、连续自适应检验族与有序账本 | scored=generated=ledger terminals；alpha_i 只能依赖先前信息，且 p/e-value 必须在同一允许 history 下条件有效；禁止只记赢家、看 p 后重排、共享输入不归簇、自适应抽样/停止后仍用固定样本 p 值、拆族或滚动重置 |
| 可报告到达 `reportable_arrival` | 初次 item、可报告修订或 assessment correction 的唯一逻辑信息到达 | 使用 `information_arrival_id` 冻结 `subject_identity_id/kind/concrete_type`、arrival kind/semantics version、`information_arrival_at` 与 nominal slot；initial 指向 RawItem object，revision 指向 RevisionAssessmentVersion record |
| 报告放置 `report_item_placement` | 某个 ReportableArrival 在一次 Publication/ReportAmendment 展示事件中的不可变 first/backfill 放置 | 必填 `presentation_event_id` 与 `item_order`；展示事件内 arrival/order 唯一，每 arrival 最多一条 first，补录保存 `backfill_of_report_schedule_slot_id` |
| 卡片放置 `report_card_placement` | selected CandidateSelectionUnit 在一次 Publication/ReportAmendment 展示事件中的不可变卡片位置 | 绑定 selection unit/decision、candidate、surface、card order 和渲染 SignalVersion；与原始资讯首发/补录语义分离 |
| 主张生成单元/决定 `claim_generation_unit` / `claim_generation_decision` | 由 presentation event、typed container、pipeline manifest/schema hash、slot key 与 ordinal 确定性派生的原子主张义务及唯一终态 | min/max/required/empty-state 分母不能由实际输出反推；outcome=claim 时恰有一个 ReportClaim |
| 主张表达/引用 `claim_expression_variant` / `claim_citation` | 每 locale/channel/variant role 的语义等价表达，以及 claim 到 exact source version/scope/rights/citation role 的关系 | 客户端不得临时翻译；合法但无关 title/quote 不得冒充证据 |
| 原始资料列示 `raw_source_listing_reference` | 无 claim 的原始资料列表中，ReportItemPlacement 到 exact source metadata/title/rights/hash 的关系 | 永不含 report_claim_id、永不使用 evidence/support 标签；与 ClaimCitation schema 互斥 |
| 呈现计划/累计快照 `presentation_render_plan` / `presentation_content_unit` / `composed_presentation_snapshot` | 每 event 唯一 typed render graph，以及 initial/amendment head 的完整累计视图 | kind-specific child、最终 DOM/hash 与 plan 双向相等；当前读不拼 base+deltas |
| 实时表面/快照 `radar_surface` / `global_radar_snapshot` / `radar_card_placement` | 跨刷新稳定表面、完整公共快照与其中的 selected card | 只有 RADAR_PUBLICATION expected-head 可成为 current；RadarViewToken/Continuation 绑定 snapshot/event/query/member |
| 注意力位置/交付 frame/机会/representation/delivery | 选择后的可达位置、带 audience_unit_type/namespace/linkage uncertainty 的合格身份单位×内容×窗口交付机会、committed render 的 expected bytes 与实际 payload | placement 不等于 delivered exposure；bot/prefetch/replay 不得膨胀同一单位 reach，没有 person-level oracle 不得把账号/设备/token 写成 unique people；delivery 必须精确等于 representation 并绑定全部撤权域 |
| 评价 arm/义务/验证证据/结果框/暴露/能力声明 family | 每个系统/基线 arm 的完整输出快照、每 horizon 唯一 snapshot/result、验证支持/反证/排除全量分母、现实 outcome 分母，以及 outcome actor 与验证证据生产者暴露终态 | arm outputs=obligations/results；验证证据资格与生产者暴露均全量闭合；系统诱导的验证不能冒充独立复现，漏 arm 输出、反证、行动者、现实结果或只挑幸运协议均阻断 |
| 事件基座 `event_base` / `event_causal_parent` | 所有状态、闭合和治理事件的共同不可变身份与跨域 happens-before 关系 | subtype 共用 EventBase ID；因果边使用复合主键、自环/时间/sequence/queue-proof 与 serializable DAG 门禁，旧 as-of 不被迟到边改写 |
| 取代事件 `supersession_event` | 记录一个不可变版本何时、为何被后继版本取代 | 只追加；权威 Version 行不保存或回写事后闭合终点，查询只返回 `projected_system_to/projected_valid_to` |

规范关系链为：

```text
capture -> raw_artifact
content_cursor -> content_cursor_checkpoint -> capture
capture + raw_item -> raw_item_version -> canonical_item/translation_artifact_version
source_endpoint_version + publisher_account_version + owner_group_version + rights_snapshot -> source_registry_snapshot
source_discovery_program -> source_discovery_frame_opportunity -> source_discovery_frame_decision -> source_discovery_frame -> source_discovery_opportunity -> source_discovery_decision
rights_grant_version + authorized_content_scope -> purpose_authorization
raw_item_version -> revision_assessment_version
canonical_item -> source_lineage/event_cluster/evidence_unit
evidence_unit + observation -> observation_version
signal_input_union -> coverage_item -> candidate_generation_unit -> candidate_generation_decision -> signal_candidate -> signal
hypothesis_test_opportunity -> test_statistic_input_snapshot -> sequential_hypothesis_ledger_entry
signal_candidate -> candidate_selection_unit -> selection_decision -> report_card_placement -> report_edition
raw_item_version/revision_assessment_version -> reportable_arrival -> report_item_placement -> report_edition
presentation_event + typed container + manifest claim slot/ordinal -> claim_generation_unit -> claim_generation_decision -> report_claim
report_claim -> claim_expression_variant + claim_citation -> presentation_content_unit -> presentation_render_plan
publication/report_amendment -> composed_presentation_snapshot -> ReportViewToken
radar_surface + global_radar_snapshot + radar_card_placement + render plan -> RADAR_PUBLICATION head -> RadarViewToken/RadarContinuation
attention_delivery_frame -> attention_delivery_opportunity/decision -> presentation_delivery
outcome_frame -> outcome_generation_unit/decision -> outcome_unit/candidate_outcome_link -> outcome_actor_exposure_unit/decision -> intervention_exposure_status
evaluation_arm_manifest -> evaluation_arm_generation_unit/decision -> evaluation_arm_output_snapshot -> evaluation_obligation/result
evaluation_corpus_snapshot + protocol -> validation_evidence_eligibility_unit/decision -> support/counterevidence/exclusion sets
validation evidence producer/operator -> validation_evidence_producer_exposure_unit/decision -> independent/system-induced validation
```

信号检测输入 `signal_input_union` 必须允许：

```text
event_cluster | observation_series_snapshot | concept_cluster_delta |
claim_relation_delta | actor_action
```

其中 `event_cluster` 必须指向具体 `event_cluster_version_id`，`concept_cluster_delta` 必须冻结 from/to `concept_cluster_version_id`，`claim_relation_delta` 必须冻结 before/after `claim_relation_version_id`，`actor_action` 必须指向具体 `action_version_id`，观察序列快照必须引用 `observation_version_id`。所有输入还必须冻结 `source_registry_snapshot_id`，并经该快照解析到当时可见且对相应观察时间适用的 `publisher_account_version_id`、`owner_group_version_id` 和 `rights_snapshot_id`。稳定身份不承载可变文本、成员、阶段或来源画像。

价格、招聘、采购、代码提交、关系变化、语义迁移和缺失/衰退序列可以不属于单一事件。系统不得为了满足事件模型而伪造 `event_cluster`。

覆盖系统使用 `coverage_item` 作为 L2/L3 计数投影。它必须有稳定 `coverage_item_id`，其 `kind` 是上述联合类型之一，并持有覆盖矩阵主标签。每个 `signal_candidate` 可以关联多个 `coverage_item_ids[]` 和零到多个 `event_cluster_ids[]`，但必须指定一个 `primary_coverage_item_id`、一个 `primary_coverage_cell` 和唯一 `allocation_lane`，因此每次选择只消耗一次主预算。文档数不能直接当作独立证据数，信号也不能只是主题标签。

`coverage_item_id` 必须由 `coverage_projection_key = canonical(scope_snapshot_id, coverage_policy_version, projection_semantics_version, kind, typed_input_refs, primary_stratum_version_ids, projection_role)` 通过固定 namespace UUIDv5 生成，数据库验证重算 ID 并对完整 key 唯一。随机客户端 ID、字段顺序和并发写入不能复制同义 item；多投影的 role 必须在 CoveragePolicyManifest 预登记。冻结 scope 漏建或重复 projection key 均形成 WatermarkGap，不能进入 coverage/generation 完整分母。

### 2.2 弱信号

弱信号满足以下语义：

> 当前绝对规模可能很小、结论仍不稳定，但相对于其历史基线，已经出现新颖、异常、加速、扩散、收缩、跨域耦合或现实行动变化的可追溯迹象。

弱信号不是“小新闻”的同义词。一个主题即使流量很大，也可能没有新的变化；一个只有三条独立记录的现象，也可能因为历史上从未出现而值得观察。

### 2.3 热点、事件与弱信号的区别

| 类型 | 核心问题 | 典型依据 | 展示位置 |
|---|---|---|---|
| 事件 | 发生了什么 | 可验证事实 | 事件流 |
| 热点 | 现在什么被大量关注 | 绝对讨论规模与覆盖范围 | 全球热点栏目 |
| 弱信号 | 什么正在以异常方式变化 | 相对基线、新颖性、扩散与行动 | 弱信号栏目 |
| 推演 | 如果变化持续，可能影响什么 | 明示假设的因果分析 | 对话或分析区，不作为事实 |

同一对象可以同时属于热点和弱信号，但两者必须分别计算、分别展示。

### 2.4 “无个人预设”的工程定义

全球雷达必须只使用公共采集配置、覆盖矩阵、版本化算法和原始语料。下列数据不得进入采集、候选生成、特征计算、信号类型准入、预算分配或栏目排序：

- 用户点击、停留与收藏；
- 用户历史对话；
- 用户关注主题；
- 用户观点与信念；
- 针对单个用户训练的画像或嵌入。

个人数据可以在隔离的对话层用于解释和比较。相同时间切片、相同系统配置下，不同用户必须得到相同的全球候选集和排名结果。该隔离也约束版本晋升：点击、对话、MemoryCandidate/UserMemory、个人“是否新颖”反馈和任何可链接个人认知的数据，不得作为全球 acquisition、coverage、detector、ranking、model 或 policy 训练、评估、champion/challenger 晋升的输入；固定配置下不变但下一版本被个人反馈改变，同样算隔离失败。

用户可以提交实体、翻译、来源依赖或事实错误的纠错建议，但建议必须先进入个人域隔离的 `correction_proposal` 队列。accept/reject/withdraw 都以 `CORRECTION_PROPOSAL_DECISION` 的连续 revision/expected-head CAS 追加，不能更新 status。它不得直接改写全局对象、特征或排名；只有经过与用户身份无关的公共证据规则或人工治理后，才能生成只含公共命题与公共证据、面向所有用户的新全局版本，并保留修改依据、审查者和生效时间。用户身份、立场、兴趣与私有附件不得进入全局对象或日志；未接受提议及私人批注遵循个人域保留/删除策略。

### 2.5 当前查询与个人数据生命周期

`PersonalScope` 是所有私有数据的强制租户根，PersonalScopeVersion 冻结 owner principal 与 authz/revocation epoch。ConversationTurn、PrivateQueryContext、QueryPlanRecord、MemoryCandidate、UserMemory/Version、CorrectionProposal，以及 embedding、缓存、分页/导出任务、备份、provider job 和 capability token，必须复合绑定同一 `(personal_scope_id,personal_scope_version_id,owner_user_principal_id)` 并由 RLS/服务凭据执行；直接 ID、重放 token、恢复或 provider callback 均不得跨租户泄露存在性。公共 CorrectionEvent、训练/评估、版本晋升与公共模型任务只允许消费 `PublicOnlyInputSnapshot`，并证明 private-lineage count=0。

当前问题的 neutralization 必须在个人域内完成。原始问题保存为 `private_query_context`，送给全球检索的临时 `neutral_query` 必须去除用户立场、直接标识符、秘密和不影响公共证据检索的私有细节。若去标识后无法保持语义，查询留在私有编排层；任何外部模型传输按个人数据用途另行授权，不能把私有问题伪装成公开语料。

记忆盲检索只接收 `neutral_query` 和公开全局配置，不接收历史对话、`user_principal_id`、用户观点/点击/关注、个人 embedding、个性化缓存或旧 query expansion。完整 `query_plan_record`、当前问题、私有回答、`conversation_turn`、`memory_candidate` 与 `user_memory_version` 均留在个人域；全球检索最多保存短期、无 `UserPrincipal` 引用的执行状态和受控审计 receipt。支持、反驳、替代解释和数据不足分别检索，第二阶段才可在个人域内读取记忆进行解释。

AI 从对话提取的内容默认只进入 `memory_candidate`，不会自动成为长期记忆；accept/reject/revoke 都追加 `MEMORY_CANDIDATE_DECISION`，只有有效 accepted state 关联的 UserMemoryVersion 可进入解释，revoke 必须引用此前有效 accept。只有用户确认或明确启用的规则才能生成追加式 `user_memory_version`。个人域必须支持逐项查看、更正、导出、保留期和删除。删除范围包括私有原文、query plan、embedding、缓存、派生回答、备份生命周期和获准供应商副本，只可留下不含主题与身份的操作墓碑。

任何外部模型调用先冻结 ModelTaskManifest，再由唯一 egress proxy 把实际出站字节与 OutboundPayloadManifest 对账。remote thread/file/vector/cache/batch handle 必须引用递归物化有效输入、权利、PersonalScope 与撤权依赖的 ProviderContextSnapshot，公共任务 transitive private-lineage=0。provider callback 的签名覆盖 key/version、job/invocation、body、nonce、scope/owner 与完整 RevocationDependencySnapshot；错绑、重放、并发第二终态或任一域撤权后不得产出 artifact。每个 manifest-required field 先物化 ModelOutputValidationUnit，attempts 与唯一 terminal Decision 分离，全部 required units passed 后 typed fields 才能下游。网页/provider 输出均 tainted，不能直接驱动工具、任意 URL、rights、状态机或配置；派生改写和短 remote handle 均不能洗白来源或 personal lineage。

## 3. 信号类型、预算分配轨道与产品栏目

信号类型不是互斥标签。一条信号可同时具有多个 `signal_types[]`，但每个类型必须给出独立触发依据。

| 类别 | 要识别的变化 | 典型触发 |
|---|---|---|
| 新出现 `emergence` | 历史语料中罕见的新概念、新实体、新关系或新做法 | 首次出现、新实体关系、历史语义距离高 |
| 快速升温 `acceleration` | 注意力或行动速度显著上升 | 增长率、加速度、变点、连续窗口超基线 |
| 跨圈扩散 `diffusion` | 从一个小圈层进入新的语言、地区、平台或社会角色 | 跨层数量增加、扩散熵提高、传播时滞缩短 |
| 现实落地 `real_world_action` | 讨论开始转化为资源承诺和实际执行 | 招聘、采购、投资、部署、法规、基础设施、产品使用 |
| 跨域汇合 `convergence` | 原本分离的领域围绕相同命题形成联系 | 新的跨域共现、实体关系和行动证据 |
| 叙事迁移 `narrative_shift` | 同一主题的语义、立场、使用者或问题框架变化 | 上下文分布改变、角色变化、支持/反对结构变化 |
| 衰退或逆转 `decline_or_reversal` | 讨论、采用或资源投入持续下降，或方向发生反转 | 负增长、取消、撤资、政策回撤、失败证据 |
| 结构异常 `structural_anomaly` | 数据生成机制可能已经变化，而不只是一次爆发 | 稳健变点、多指标同步偏离、原有相关性破裂 |

实现必须严格区分四个命名空间：

| 字段 | 数量 | 作用 | 示例 |
|---|---:|---|---|
| `signal_types[]` | 1..N | 描述检测到的变化类型 | `emergence`、`diffusion` |
| `allocation_lane` | 恰好 1 | 指定候选占用覆盖矩阵中的哪一个预算分配轨道 | `coverage_floor`、`public_change`、`long_tail_novelty`、`random_exploration` |
| `surface_sections[]` | 0..N | 指定候选可出现在哪些产品栏目 | `global_hotspots`、`weak_signals`、`decline_reversals` |
| `ranking_rule_id` | 每个 `selection_decision` 恰好 1 个 | 指定该候选在目标栏目使用的版本化排序规则 | `weak_signals_rank_v1` |

`allocation_lane` 的允许值恰为 `coverage_floor`、`public_change`、`long_tail_novelty`、`random_exploration`。`signal_types[]` 不能决定预算，`allocation_lane` 不能被解释为信号语义，`surface_sections[]` 不能被当作独立候选，`ranking_rule_id` 不能隐藏总分。

每个 `selection_decision` 另存 `selection_reason_codes[]`；它解释选择、未选或降级，不构成第五种决策命名空间，且只能引用第 17.1 节权威原因码。

除上述信号类型外，产品至少保留两个独立栏目：

- **全球热点**：按绝对规模与跨区域覆盖展示当前重要事件；
- **盲区探索**：从低曝光地区、语言、领域和来源类型中抽样，不要求成为当日最高分候选。

盲区探索是防止系统自身形成信息茧房的必要机制，不得用弱信号阈值将其完全过滤。每个栏目必须始终显示其标题和方法，但某一期可以没有合格候选；此时必须显示 `empty_reason_text`、注册表内的 `empty_reason_codes[]`、覆盖债务和数据健康，禁止用低质量、重复或无证据内容凑数。

产品必须明确区分两种观察镜头：

- **规模镜头 `prevalence_lens`**：回答“在可观察范围内，什么的绝对规模最大”。它使用可比采样与分母校正后的规模，不通过地区、语言或领域配额改写大小，主要服务全球热点；
- **探索镜头 `exploration_lens`**：回答“哪些小规模、低曝光或陌生分层值得被看见”。它使用分层配额、弱信号规则和随机探索，主要服务认知拓展。

探索镜头中的入选位置不得被表达为全球流行程度，规模镜头中的高排名也不得挤占探索名额。两种镜头共享原始证据，但独立生成列表和选择理由。

## 4. 候选生成

### 4.1 输入与前置处理

候选生成只可读取以下版本化数据：

- `raw_item` 的许可内快照或受权限控制的元数据指针；
- `canonical_item`、`source_lineage`、`event_cluster` 与 `evidence_unit`；
- 条目/版本的发布时间、首次发现、捕获和更新时间；
- 冻结 `source_registry_snapshot_id` 中的端点、`publisher_account_version_id`、`owner_group_version_id`、角色、地区、预期采集节奏与历史 `rights_snapshot_id`；
- 去重、溯源和独立性结果；
- 自动翻译，但必须保留原文并记录翻译模型版本；
- 事件簇、观察序列、概念簇、主张关系和行动者行动；
- 公共覆盖矩阵与采集健康状态。

进入检测前必须完成：

1. 精确重复与近似重复识别；
2. 转载、引用和共同原始出处识别；
3. 按本次运行 `as_of` 可见、且对相应观察时间适用的 `PublisherAccountVersion` 与 `SourceRegistrySnapshot` 生成语言、地区、领域、来源类型、社会角色分层；
4. 发布时间与可用时间校正；
5. 采集缺口和来源中断检测。

第 3–5 步不得调用“当前来源资料”。所有权独立性必须由同一快照中的 `OwnerGroupVersion` 计算；采集机会分母只能展开该快照所引用 CollectionPlanManifest 的 `planned_poll_cadence`，`source_declared_update_cadence` 仅用于描述和偏离审计；历史资格使用其中引用的 rights snapshot。执行时仍须按第 9.2 节以最新权利 epoch 重新授权。后来获知的收购、角色/地区重分类、权利或采集节奏变化只能进入新的来源版本/快照，不得修改既有特征或候选。若当时所有权未知，原运行保留 unknown；新知识只能进入新运行，并按第 13 节区分操作回放与回顾性重分析。

### 4.2 分层检测

候选不得只在全局总语料上生成。检测至少按以下维度分层运行，并保留交叉层结果：

- 地区；
- 语言；
- 领域；
- 来源类型，例如新闻、论文、专利、公告、政策、招聘、社交媒体；
- 可观察行动者类型，例如科研机构/研究者、企业/从业者、资本机构、政府/政策机构、媒体、社区账号；
- 实体、事件、主张和关系类型。

具体分层与最低覆盖量由《全球信息覆盖矩阵》的 `CoveragePolicyManifest.required_cells` 定义。本规范不要求五个维度的完整笛卡尔积；只有 manifest 列出的单维和高风险交叉格承担硬 SLA，其余交叉格仅观察、记录债务或按策略探索。所有特征必须记录其计算所用的 `coverage_stratum_version_ids[]`、`coverage_policy_version` 和 `source_registry_snapshot_id`；涉及发布者时还要记录实际使用的 `publisher_account_version_ids[]` 与 `owner_group_version_ids[]`。禁止将不同体量的分层直接比较绝对数量，或用当前分类边界、角色、地区和所有权重新标注过去窗口。

开放世界检测不得以“先成功归入既有 14 领域（或任何后续固定枚举）/已知主题”为候选前置条件。D05/D06 的词汇/语义新颖、D09 的关系新颖都可先形成记录新颖度测量及其分母的 `observation_series_snapshot`；已有合法 before/after Version 时，也可分别形成 `concept_cluster_delta` 或 `claim_relation_delta`，但不得为首现伪造 from/before ID。相关 ConceptClusterVersion、ClaimRelationVersion 或 ObservationSeriesSnapshot 可以保留 `domain_status=unknown`，不要求先映射已知主题。此类输入仍必须形成可追溯的 `coverage_item`，并在证据和安全门禁通过后允许形成 `signal_candidate`；其主覆盖格使用当时的 unknown 分层版本，`allocation_lane=random_exploration`，进入覆盖政策预注册的 `random_exploration` 子分层。unknown 表示分类知识不足，不是数据质量失败，也不得由模型强行贴入最相近的已知主题；它仍须遵守去重、权限、证据定位、操纵风险和暖机门禁。

即使所有 D01–D11 都返回 no-candidate，冻结 scope 中每个 CoverageItem 也先确定性物化 `PreDetectionExplorationEligibilityUnit/Decision`，保存资格谓词、质量/权限证据和 detector terminal IDs；缺终态形成 gap。eligible 后才按冻结随机框物化 `PreDetectionExplorationUnit` 和唯一 terminal decision。selected 项通过 `ExplorationMaterialPlacement` 进入同一 random_exploration lane并标 `not_a_signal=true`；先看内容只为赢家建资格/unit、只保护 candidate unknown 或把它计入统计确认/prevalence 均失败。

### 4.3 `detector_manifest` 与里程碑

检测器清单只有一个权威 `detector_manifest`。M2 交付双时段报告所需的基础变化检测；M3 在其上完成全部 11 个弱信号检测器，从而避免“11 个必做检测器”和“6 个基础检测器”两套口径。

| ID | 检测器 | `signal_input_union` | 首次要求 | 输出条件 |
|---|---|---|---|---|
| D01 | 频率突增 | 概念簇、实体、关系、主张、行动 | M2 | 当前窗口相对季节性基线显著升高 |
| D02 | 速度与加速度 | 观察序列 | M2 | 增长速度继续提高，而非单次峰值 |
| D03 | 下降与逆转 | 观察序列、行动者行动 | M2 | 覆盖健康校正后持续下降或出现相反行动 |
| D04 | 稳健变点 | 观察序列 | M3 | 数据生成分布出现变化点 |
| D05 | 新颖语义 | 概念簇、主张关系、行动组合 | M3 | 与当时可用历史语料距离高，且不是翻译或改名造成 |
| D06 | 首现与低频复现 | 新实体、新短语、新关系 | M3 | 首次出现，或低基数下在独立样本中复现 |
| D07 | 跨层扩散 | 概念簇、主张、事件簇、行动者行动 | M3 | 进入新的语言、地区、来源类型或行动者角色 |
| D08 | 现实行动 | 行动者行动 | M3 | 出现招聘、资本、采购、部署、法规等可验证行动 |
| D09 | 跨域关系 | 主张关系、知识图谱边 | M3 | 原本稀疏的领域之间出现新关系并持续 |
| D10 | 叙事迁移 | 概念上下文、立场、行动者角色 | M3 | 上下文、发言者构成或问题框架显著改变 |
| D11 | 关联破裂 | 指标对、实体关系 | M3 | 长期稳定的关系异常减弱或反转 |

`DetectorManifest` 使用唯一 `detector_manifest_id`；其中每个 entry 都必须引用 canonical `detector_id` 与不可变 `detector_version_id`，并保存展示用 `detector_key`（D01–D11）、输入类型、所需特征、窗口、暖机门槛、候选规则、确认规则、允许的 `signal_types[]`、适用里程碑和退役时间。D01–D11 只是稳定的人类可读 key，不能替代 Detector/DetectorVersion 身份或规则版本。M3 完成时 D01–D11 对应版本均须可运行；里程碑不是第二套清单。

所有检测器输出候选的并集，不能要求候选同时通过全部检测器。检测器必须返回触发规则、原始测量、基线、异常程度、适用 `stratum_version_id`、`evidence_unit_ids[]`/`evidence_scope_ids[]`、暖机状态和算法版本；仅返回自然语言结论不合格。

### 4.4 高召回策略

候选阶段以高召回为目标，允许单一独立来源进入 `candidate` 状态，但必须标为“单源、未确认”。不得为了提高表面命中率，在候选阶段只保留已有主流媒体确认的主题。

检测器在容量允许时返回全部合格候选；存在算力或展示预算时，按照《全球信息覆盖矩阵》的 L2/L3 覆盖债务、公共变化、长尾新颖与随机探索策略调度，不能使用一个全球 Top-K 截断长尾。本规范不另设比例；覆盖矩阵是候选预算配额的唯一权威来源。

任何配额调整都必须版本化，并通过回放评估其对地区、语言、领域和来源集中度的影响。配额只用于探索镜头的计算/展示资源调度，不得改写规模镜头中的全球热点估计值或排名。

每个 `signal_candidate` 在首次冻结时必须分配不可变 `candidate_id`、`candidate_frozen_at` 和按预注册 `proposition_family_rule_version_id` 计算的 `proposition_family_id`，并保存 `evaluation_protocol_version` 与协议 hash。候选冻结记录还保存：初始 `signal_types[]`、`input_refs[]`、`coverage_item_ids[]`、`primary_coverage_item_id`、`primary_coverage_cell`、`event_cluster_ids[]`、`source_registry_snapshot_id`、实际使用的 `endpoint_version_ids[]`/`publisher_account_version_ids[]`/`owner_group_version_ids[]`/历史 `rights_snapshot_ids[]`、`coverage_stratum_version_ids[]`、唯一 `allocation_lane`、候选可进入的 `surface_sections[]`、`detector_manifest_id`、触发它的 `candidate_generation_decision_ids[]` 及其 `detector_version_id`。这些初始输入和检测证据进入候选 commitment 后永久不可变。每个目标栏目单独产生一个 `selection_decision`，其确定性 `selection_unit_id` 绑定选择运行/slot、candidate、栏目与 allocation context，并保存单一 `surface_section` 与 `ranking_rule_id`；同一 unit 只能有一个 terminal 决定。候选可记录 `eligible_allocation_lanes[]` 用于审计，但只能在主 `allocation_lane` 消耗一次预算；进入多个产品栏目也不得重复占用预算或重复计算为多个候选。

候选发射必须幂等。预注册 `CandidateEmissionPolicy` 定义不重叠检测窗、窗口归属、重触发/冷却/复活条件和规范序列化；覆盖、方法或来源宇宙发生不可连续比较的 break 时创建新的 `BaselineEpoch`，不得回填旧候选。系统计算：

```text
candidate_emission_key = H(proposition_family_id || emission_policy_version ||
                           baseline_epoch_id || nonoverlapping_detection_window)
```

`signal_candidates.candidate_emission_key` 必须有唯一约束，创建采用原子 get-or-create。重试、并发 worker、检测器 patch/minor 版本升级、映射到同一不重叠检测窗的相邻重叠滚动窗，或多个检测器命中同一 key 时，只追加复用 EventBase.event_id 的 `CandidateTriggerEvent`，保存新的 AnalysisRun/FeatureArtifact/EvidenceUnit/输入引用；严禁更新候选冻结行、初始 detection universe 或 commitment。实际 Signal 生命周期变化另追加 `SignalStateEvent`。这些触发事件不是第二个候选，也不增加评价分母。只有预注册 emission policy 进入新的 nonoverlapping window，或真实 baseline break 产生新 `baseline_epoch_id`，且满足重触发/复活条件时，才可形成新 key 和新候选；merge/split/Signal 映射不得事后改 key。检测器、family 或 emission policy 的实质变更产生新规则版本，但不重写已经冻结的 key。

### 4.5 合并与拆分

候选之间必须按命题语义、实体、时间、因果方向和证据起点进行聚类。

- 同一事件的不同报道应合并；
- 同一主题下方向相反的命题不得合并；
- 一个大主题包含多个独立变化时应拆分；
- 合并与拆分必须通过追加式映射或 `signal_state_event` 保留旧 ID、版本和关系；不得删除、重写或复用既有 `candidate_id`；
- 信号标题变化不得改变其历史身份；命题实质变化则必须产生新版本或新信号。

候选冻结后的 merge、split、reactivate 或映射到另一 `signal_id` 都不得改变 candidate-level 评估分母和既有 `proposition_family_id`。复活周期可以产生新的 `candidate_id` 并链接旧候选，但旧候选仍保留一次；不得失败时把候选合并掉、成功时把一个候选复制成多个命中。能力报告必须同时给出 candidate-level 结果和按冻结 `proposition_family_id` 聚合的 family-level 结果。

## 5. 时间基线

### 5.1 条目、版本与双时间语义

每个来源对象使用稳定 `item_id`，每次内容变化或重新捕获使用不可变 `item_version_id`。原始时间字段必须区分：

- `event_time`：事件实际发生时间或区间，未知或推断时明确标记；
- `source_published_at`：来源声明的首次公开时间；
- `source_updated_at`：来源声明的更新时间，未知时为空；
- `item_first_seen_at`：系统首次成功观察并登记该 `item_id` 的时间，永久不向过去回推；
- `version_observed_at`：系统首次捕获该 `item_version_id` 的时间；
- `captured_at`：该版本原始快照安全落盘的时间；
- `version_available_at`：该原始版本通过许可、完整性和安全门禁，可供获准下游读取的时间。

必须满足 `item_first_seen_at <= version_observed_at <= captured_at`；版本通过门禁时还必须满足 `captured_at <= version_available_at`。初始版本的前两者通常相同，但不得用 `source_published_at` 复制或倒填。被安全或权利门禁拒绝的版本允许 `version_available_at=null`，但拒绝决定与时间必须可审计。

派生记录的字段不能由 `*Version/*Snapshot` 后缀推断，必须逐对象读取《统一数据、时间与决策契约》第 5.1、7.2 节的 archetype 与 time-profile registry：

- 只有 time-profile registry 明确登记为 `bitemporal_version_time` 的记录保存 `valid_from/asserted_valid_until`、`system_from`、`system_available_at`、`as_of` 与 `run_mode`；查询时由当时可见的 SupersessionEvent 投影 `projected_system_to/projected_valid_to`；
- FeatureArtifact、CoverageItem、SignalCandidate、CandidateGenerationDecision、SelectionDecision、ReportClaim、AnalysisRun、ModelOutputArtifact、ReportEdition 等普通 immutable record 使用各自登记的 system-availability profile，不得补造业务有效区间或 supersession；
- standalone snapshot 使用 `snapshot_frozen_at/system_available_at/as_of` 和物化输入清单，不拥有虚构的 snapshot parent 或闭合区间；manifest 使用配置生效时间；RawItemVersion 继续使用本节原始版本时间；
- 每个 record 至少有 time-profile registry 指定的 `system_available_at` 或同义的受控不可变可用时间，CI 对未登记对象 fail closed。

世界有效时间确实未知或不适用时，bitemporal version 的 `valid_from/asserted_valid_until` 可以为空，但必须保存 `valid_time_status=unknown|not_applicable`，不得复制 `source_published_at` 制造虚假业务时间。操作回放对原始版本要求 `version_available_at <= T`；对其他记录先要求其登记的 system-availability time `<= T`，只有 bitemporal version 再要求 `system_from <= T < projected_system_to(T)`。因此 T 后形成的别名、聚类、来源角色/地区分类、所有权关系、权利/节奏修订、修订重分类、特征、候选或知识图谱边都不可见。

所有权威行不可变，但只有登记为可取代版本或 event-sourced state 的对象才使用闭合事件。计划、执行、取消分别形成三个 `actor_action_version` 和相应 SupersessionEvent；ClaimRelationVersion、ObservationVersion、SourceEndpointVersion、PublisherAccountVersion、OwnerGroupVersion 与 RevisionAssessmentVersion 同理。新的 SourceRegistrySnapshot 只引用新旧 Version 的适用组合，不改写历史快照；普通 immutable record 和 standalone snapshot 不因“后来有新记录”而虚构 supersession。

关键系统时间统一使用 UTC，并保存 `clock_source_id`、`clock_skew_bound_ms`、`clock_health_snapshot_id` 与写入域内单调递增的 `ingest_sequence`。序列只在本写入域内可比较；跨域 happens-before 必须由不可变 `causal_parent_event_ids[]` 与队列 offset 证明，不能比较两个本地序列大小。`item_first_seen_at`、`version_observed_at` 和 `decision_system_available_at` 只能由受控登记服务赋值，不能采用采集/分类 worker 的任意本地时钟。时钟倒退、跨节点偏移超阈值、闰秒处理异常、重启后序列异常或时间源不可用时设置 `time_quality=degraded` 与原因码 `CLOCK_UNTRUSTED`，隔离受影响输入并令相关报告 `edition_status=degraded`；这些对象在恢复前不得进入精确窗口归属、提前量或跨分层比较。来源自报时间不能修复系统时钟。

`raw_item_version` 只保存实际观察到的不可变内容/元数据及上述原始时间，不把 `revision_type` 或 `reportability` 写成可改字段。每个非初始版本关联稳定 `revision_assessment_id`；其不可变 `revision_assessment_version` 同时保存 before/after `item_version_id`、`revision_type`、`reportability=non_reportable|reportable|unknown`、输入 diff、规则/模型/运行、理由与 `decision_system_available_at`。`decision_system_available_at` 是该判断被受控登记服务追加并首次可用于下游的 UTC 时间；它不得回填。重分类只追加新的 `RevisionAssessmentVersion` 与 `supersession_event`，不得改 `raw_item_version` 或旧 assessment。

定义 `information_arrival_at`：初次内容等于 `item_first_seen_at`。旧 item 新版本第一次得到 `reportable|unknown` assessment 时，其底层信息到达为 `version_observed_at`，但在对应 `RevisionAssessmentVersion.decision_system_available_at` 之前不具备处理资格；若判断赶不上原窗口水位，按 `processing_backfill` 处理而不是移动原到达时间。第一次判断为 `non_reportable` 时不进入报告流，但该 raw version 的底层到达时间仍不改变。以后 assessment 在 non-reportable、reportable 与 unknown 之间任意重分类时，原 `information_arrival_at` 均不改；系统只在新 assessment 的 `decision_system_available_at` 追加 `REVISION_ASSESSMENT_CORRECTION`，说明先前依据并重算当前投影，不得倒填旧运行、静默删除旧 edition 或重复首发。`version_available_at`、assessment 的 `decision_system_available_at/system_available_at` 与其他派生 `system_available_at` 共同决定是否赶得上实际处理水位。`source_published_at` 和 `event_time` 只用于叙事、事件排序和历史时间轴。

系统必须区分至少以下五种时间结果：

| 类型 | 定义 | 报告处理 |
|---|---|---|
| 首次发现 | 新 `item_id` 第一次被观察 | 按 `item_first_seen_at` 归属名义窗口 |
| `discovery_delay` | `item_first_seen_at - source_published_at`，仅在来源时间可信时计算 | 按本期到达正常首发并显示 `DISCOVERY_DELAY`；旧文不能写成刚发生 |
| `processing_backfill` | `information_arrival_at` 属于更早窗口，但原始版本或必要派生对象没有赶上相关水位 | 下一期补录并使用 `PROCESSING_BACKFILL`，保留原名义窗口、延迟阶段和原因 |
| 可报告版本更新 | 旧 item 新版本的首个 `RevisionAssessmentVersion.reportability` 为 reportable/unknown | 底层到达按 `version_observed_at`；判断在 `decision_system_available_at` 后才可处理。纠错、撤稿、实质新增分别使用 `CORRECTION`、`RETRACTION`、`MATERIAL_UPDATE`；unknown 保守进入更新流，但分类前不得新增事实主张 |
| 可报告性重分类 | 同一 raw version 后来的 assessment 在 non-reportable/reportable/unknown 之间变化 | 原 `information_arrival_at` 不变；按新 assessment 的 `decision_system_available_at` 追加 `REVISION_ASSESSMENT_CORRECTION` 并重算当前投影，不修改 raw version、旧判断、旧窗口或旧 edition |
| `SOURCE_TIME_CHANGE` | 来源修改自报发布时间或其他会影响时间线的元数据 | 它不是 `revision_type`；若改变既有报告时间线、作者归属或其他语义，assessment 只能是 `revision_type=metadata_update, reportability=reportable`，按判断可用时间进入更正区并使用 `SOURCE_TIME_CHANGE`，不得静默改旧版 |

同一 `RevisionAssessmentVersion` 中，`revision_type` 必须是 `format_only`、`metadata_update`、`correction`、`retraction`、`substantive_addition` 或 `unknown_revision`，`reportability` 独立为 `non_reportable|reportable|unknown`。`format_only` 必为 non-reportable；纠错、撤稿和实质新增必为 reportable；`metadata_update` 按是否改变既有报告语义决定；unknown 按可报告保守进入更新流，分类后只追加修正。系统抽取修复、实体合并/拆分和政策红删另建派生 `correction_event`。任何评估或更正都不得静默改写旧日报。

### 5.2 多尺度窗口

同一候选应并行观察多个尺度，避免只发现短期爆点：

| 尺度 | 当前窗口默认值 | 参考基线默认值 | 主要用途 |
|---|---:|---:|---|
| 实时 | 1 小时、6 小时 | 过去 14 天同小时段 | 突发与快速扩散 |
| 日级 | 24 小时 | 过去 28 天同星期结构 | 日报与升温信号 |
| 周级 | 7 天 | 过去 13 周 | 持续变化与跨圈扩散 |
| 月级 | 28 天 | 过去 12 个月 | 慢变量、衰退和结构变化 |

当数据源采样频率不适合默认窗口时，可以按来源类型覆盖配置，但必须记录实际窗口。

北京时间 08:00 日报的名义观察窗为前一日 19:00 至当日 08:00；19:00 日报的名义观察窗为当日 08:00 至 19:00。窗口使用左闭右开区间，初次内容按 `item_first_seen_at`、旧 item 首次可报告 assessment 按第 5.1 节的 `version_observed_at` 判断原信息名义所属期；后续 `REVISION_ASSESSMENT_CORRECTION` 按新判断的 `decision_system_available_at` 进入更正流，但不改变原 `information_arrival_at`。只有原始版本、assessment 与必要派生对象都在本期相关水位前可用时才能实际进入本期；否则下一期标记 `processing_backfill`。

准时发布必须优先于伪装成整点完整：每期报告都要显示 `scheduled_publish_at`、`configured_data_cutoff`、`processing_watermarks{}`、`required_processing_frontier`、`comparison_watermark`、`selection_completeness_frontier` 和最终 `data_cutoff`。为摘要和聚类预留的处理时间由运行配置定义；在 configured cutoff 后才首次发现，或虽已到达但尚未赶上最终水位的内容，进入下一期补录。报告不得声称覆盖到晚于实际处理或选择完整前沿的时间。

- `configured_data_cutoff`：运行配置允许本期接收新 `information_arrival_at` 的最晚时间；它不是完成性声明；
- `processing_watermarks{}`：以 `pipeline_stage × purpose × stratum_version_id` 为权威键的结构化连续完成前沿映射；稳定 `stratum_id` 只供展示，不能满足完整性 FK。其 `frontier_at` 是一个 `information_arrival_at`，表示该点及以前属于冻结 scope、具备对应处理资格的全部输入已经处于成功、明确失败、隔离、删除或其他 terminal 状态，且计划采集机会和内容游标无已知空洞；
- 每个水位记录还必须保存 `pipeline_stage`、`purpose`、`stratum_version_id`、`coverage_policy_version`、`watermark_computed_at`、`scope_snapshot_id`、相关 `cursor_checkpoint_ids[]`、`watermark_gap_ids[]`、排除原因和完整度；WatermarkGap 关闭只能追加 state event，不得删除内嵌描述后越过缺口；仅仅“没有看到新内容”不能推进水位；
- 每期在首个处理任务前冻结 `ReportPipelineManifest`。其非空 `required_pipeline_keys[]` 至少覆盖 eligibility/normalization、candidate generation、selection 与 claim generation；每个 key 固定 `stage × purpose × stratum_version_id`、DetectorManifest/DetectorVersion 集、terminal record type、scope 与 completeness oracle。required keys 只能从 manifest 读取，不能从“实际跑出了哪些任务”反推；
- `required_processing_frontier`：目标 edition 的 `ReportPipelineManifest.required_pipeline_keys[]` 对应 processing watermark `frontier_at` 的最小值；
- `comparison_watermark`：当前全局比较所需各键的 `frontier_at` 最小值；热点、扩散和跨层排名只能读取该共同终点之前的数据；
- `selection_completeness_frontier`：manifest 中 candidate-generation 与 selection keys 的连续完成前沿最小值。每个 eligible CoverageItem×required DetectorVersion 必须有唯一 `generation_unit_id` 的 terminal CandidateGenerationDecision，每个 candidate×选择上下文必须有唯一 `selection_unit_id` 的 terminal SelectionDecision；任务未运行、崩溃、矛盾双终态或缺行均形成 WatermarkGap。零候选只有在所有 generation units 合法返回 no-candidate 后才是完整，空 detector 运行不能真空通过；
- `data_cutoff = min(configured_data_cutoff, required_processing_frontier, selection_completeness_frontier)`：这是 effective data cutoff，也是报告可声称“已完整处理并完成选择至”的唯一截止时间；任一组成值缺失时不能以配置 cutoff 代替，按 hard limit 发布 degraded edition 或把 slot 标 failed；
- `processing_backfill`：条目名义属于更早一期，但未赶上其相关处理水位而在本期首次展示；
- `discovery_delay`：来源较早发布但本期才首次观察；它不是处理补录。

`processing_watermark` 不是“已处理对象最大的 `system_available_at`”，也不是最后成功任务时间。一个到达很早的旧输入今天才处理完成，只能关闭旧缺口并可能推进以 arrival time 表示的连续前沿，绝不能把“今天”写成新鲜水位。若排除严重落后分层，必须生成 `edition_status=degraded` 的新 `report_edition`，使用注册原因码 `DEGRADED_COVERAGE` 或 `COMPARISON_WATERMARK_REDUCED`，公开被排除分层和敏感性，不能静默比较不等长窗口。

`ReportScheduleManifest` 必须在首个受影响名义窗口开始前冻结，保存 recurrence、`Asia/Shanghai` 时区、tzdb 版本、例外日、窗口边界、SLO 引用和确定性 slot ID 派生规则。计划分母由 manifest 推导，并与窗口前预先物化的不可变 `ReportScheduleSlot` 对账；即使系统全窗宕机而漏建 slot，也必须按 manifest 补记失败且计入分母，不能通过缺行消失。

`slot_status=scheduled|published|failed|cancelled` 是按查询 as-of 从追加事件计算的投影，不是可更新字段：失败、取消和恢复由 `ReportSlotStateEvent` 表达，published 只能由成功 `PublicationEvent` 投影。每次渲染/提交创建 `PublicationAttempt`；只有一次原子提交成功时，才同时创建与成功 attempt 一一对应的 `PublicationEvent` 和 `ReportEdition`。预览、数据库 `created_at` 或失败 attempt 不等于发布；完全漏发只有 failed slot/state event 和可选 attempt，不存在 `edition_status=failed` 的虚构版次。cancelled 默认仍留在服务分母，只有窗口开始前由 manifest 预注册且运行方不可临时触发的排除规则，才可另报 excluded cohort。

每个已发布 `report_edition` 必须保存 `report_schedule_slot_id`、成功 `publication_attempt_id`、`report_pipeline_manifest_id`、`nominal_window_start/end`、`scheduled_publish_at`、原子发布时写入的 `publication_committed_at` 与唯一 `publication_event_id`。版次保存 `configured_data_cutoff`、全部 required processing watermark IDs、manifest 的 `required_pipeline_keys[]`、`required_processing_frontier`、`comparison_watermark`、`selection_completeness_frontier`、最终 `data_cutoff`、candidate-generation/selection/claim-generation unit 与 decision IDs、完整 ReportItemPlacement/ReportCardPlacement/ReportClaim 顺序、PresentationRenderPlan/PresentationContentUnit 清单、`publication_lag_minutes`、`cutoff_lag_minutes` 及单期采集/解析/provenance/selection 实际值。PublicationEvent、ReportEdition、两类 placement、claim obligations/claims 与 render plan 在同一事务提交；数据库同时约束每 slot 只有一个 initial publication、每 presentation event 的 arrival/card/order 唯一、每 arrival 最多一个 first placement，并对 required claim slots 与最终输出做双向集合相等。`cutoff_lag_minutes` 必须按 `scheduled_publish_at - data_cutoff` 计算，不能按更乐观的 configured cutoff 计算。

单期状态与滚动服务 SLO 必须分开：已发布版次的 `edition_status=normal|degraded` 只由该期 hard limits 和完整性门禁决定，`edition_reason_codes[]` 只能引用第 17.1 节的权威注册表；滚动准时率和 cutoff-lag P95 只决定版本化 `service_slo_snapshot` 中的 `service_slo_status=warming_up|meeting|breached`。二者共同引用 `slo_config_version`，但滚动平均不得把一份严重陈旧的版次伪装为正常，也不能因历史 breach 把当前合格 edition 降级。发布提交必须原子核对最新 `revocation_epoch`。production SLO 生效前使用版本化 `provisional_slo_v1` 并明确标为 shadow；后续 `production_slo_v1` 不得回写旧试验结果。

#### 5.2.1 实时雷达 current-head

实时窗口与日报共享候选、证据、水位和公共非个性化规则，但不共享 schedule-slot 发布身份。每个稳定 RadarSurface 由 RadarPipelineManifest 冻结 scope/method epoch、required pipeline keys、selection surfaces、claim-slot schema、render channels 和 head-dominance 规则；每次准备完整 GlobalRadarSnapshot，冻结 watermarks/frontiers/data cutoff、generation/selection/claim decisions、features、RadarCardPlacements、ReportClaims、PresentationRenderPlan/PresentationContentUnits、rights snapshot/epoch 与状态。

只有 `RADAR_PUBLICATION` EventBase subtype 能成为公共 current head。它以 RadarSurface 为 aggregate 执行连续 revision 的 expected-head CAS，并与完整 snapshot/card/claim/render 集合在一个 serializable 事务闭合；预览、孤儿 snapshot、部分卡片、旧 worker 重放或逐表 `MAX(system_available_at)` 均不可见。同一 scope/method epoch 内 as-of/frozen time 严格前进，所有同 key frontiers、data cutoff 和 rights epoch 不倒退；不可桥接方法/范围变化必须新建 epoch、标 `COVERAGE_SHIFT` 并重新暖机。

一次读取绑定签名 `RadarViewToken(surface_id, head_revision, snapshot_id, revocation_epoch, render_plan_hash, expires_at)`，先完整物化响应并在首字节前重验。撤权 epoch 变化使旧 head 整体失去展示资格，返回 `RADAR_VIEW_RECOMPUTING|RADAR_VIEW_UNAVAILABLE`，直到最新 epoch 全量重算并原子替换；分页、详情、缓存与导出均不得跨 token 补卡或逐卡红删。应用层结果只能是一个完整旧/新 snapshot 或明确不可用，不能形成旧排序加新墓碑、跨 snapshot feature/selection/card 或跨 epoch 文本。

任何“未出现”“正在减少”的判断都只能使用完成水位之前且采集健康的区间。

### 5.3 基线计算

基线必须同时满足：

1. **季节性校正**：校正小时、星期、节假日和来源固有发布节奏；
2. **稳健统计**：优先使用中位数、MAD、分位数、EWMA、CUSUM 或贝叶斯变点，避免均值被单次峰值污染；
3. **稀疏收缩**：低基数序列采用贝叶斯/经验贝叶斯收缩和可信区间，禁止用接近零的分母制造无限增长率；
4. **分层归一**：在相同语言、地区、领域和来源类型内计算分位数，再讨论跨层比较；
5. **采集健康校正**：来源数量、抓取成功率、接口限流或平台中断异常时，暂停或降级相关结论；
6. **分母稳定**：同时计算原始计数、文档占比、活跃来源占比和可用采集机会；分母变化时禁止只用计数判断升降；
7. **抽样概率**：已知抽样概率的数据保留纳入概率并在适用时做逆概率校正；未知抽样率的平台只能做平台内相对判断，并标记限制；
8. **多重检验**：有统计显著性语义的检测器必须记录同时检验的候选数及 `q_value`；非概率检测器记录经验假警报率或明确“不可用”，禁止伪造 p 值；高假阳性探索项可以保留，但必须与统计确认项分开展示；
9. **检测与确认分离**：触发候选的数据不能同时被当作独立确认；确认窗口必须与检测窗口在时间和证据集合上断开，或使用真正独立的数据生成过程，以控制“赢家诅咒”；
10. **方法版本可比**：抽取器、分类器、分词、翻译或采样方法改变后，必须用同一版本重算可比基线，或明确断开时间序列；
11. **历史版本冻结**：每次运行记录基线截止时间、样本数、方法和参数版本。

每个数值特征必须同时保留：原始值、基线值、变化量、分层分位数、置信区间、样本支持度和缺失标记。

第 8 条的多重检验必须从评分机会之前闭合。`SequentialTestingUniverseManifest` 在数据访问前展开每个 `HypothesisTestOpportunity`；任何计算筛选分数、p/e-value 或决定是否建 test 的机会都有唯一 generation terminal，且 `scored_opportunity_ids = generation_terminal_ids = ledger_terminal_ids`。每个 family 是同一 root alpha wealth 的互斥/守恒子分区，重叠 scope、动态 sibling、迁移和 reset 满足 `sum(child_alpha_debit) <= root_alpha_wealth`。评分后只登记赢家、为赢家拆族、漏机会、wealth 回滚或每窗重置时使用 `MULTIPLE_TESTING_UNCONTROLLED`，只能探索，不能确认、声明能力或晋升。

机会完整和 wealth 守恒仍不足以证明 online-FDR 有效。每个 opportunity 必须在其 test statistic、p/e-value 或任何同窗/未来结果可读前，以不可变 commitment 冻结 `logical_test_order`、`threshold_reservation`、family predecessor 与允许的信息集；实际 `alpha_i`/e-threshold 必须由冻结方法仅使用严格早于该逻辑序号的 ledger history 确定性重算。异步完成只改变执行时间，不改变逻辑结算顺序；先看全部 p 值后按显著性排序，或把大阈值只分给当前小 p 项，即使机会全量入账且总 debit 不超 root wealth，也必须标 `MULTIPLE_TESTING_UNCONTROLLED`。

阈值相对于 `history_<i` 可预测，不等于当前 p/e-value 对该 filtration 条件有效。每个 `HypothesisTestOpportunity` 必须在统计量计算前绑定内容寻址、不可变的 `TestStatisticInputSnapshot`，列出原始/派生输入、抽样与停止决定、可读的 predecessor information set、数据生成过程及 `dependence_cluster_id`；family method 同时冻结 `filtration_definition_id`、`conditional_validity_method_id` 与允许的依赖结构。验证器必须证明或用预注册 null fixture 检验 `P(p_i <= a | history_<i) <= a`，或者对应 e-process 相对同一 filtration 满足超鞅条件。两个边际均匀的 p-value 若共享输入且条件相关、同一测量被切成多个假设却不归簇、或根据中间结果改变抽样/停止后仍使用固定样本 p-value，即使机会、顺序、阈值和 wealth 全部入账，也只能标 `MULTIPLE_TESTING_UNCONTROLLED`；改用对该停止/依赖结构有效的 anytime-valid/依赖稳健方法或独立 holdout 后才可确认。

分母必须对应所声称的命题。例如“讨论占比上升”至少需要主题文档数/全部可比文档数，“更多独立行动者参与”需要独立行动者数/可观察行动者数。若无法确定合理分母，只能报告原始计数变化及其局限，不能写成总体趋势。

滚动窗口之间共享的 `item_id`、`evidence_unit_id` 或同一时间切片不得产生“再次确认”。实现必须分别保存 `detection_evidence_unit_ids[]`/`confirmation_evidence_unit_ids[]` 与 `detection_observation_version_ids[]`/`confirmation_observation_version_ids[]`，但 ID 不相交只是必要条件：live confirmation 必须与 horizon evaluation 使用同一独立性 oracle，同时核对 SourceLineage、行动者/行动身份、measurement/data-generation process 和新增时间区间。把同一 API、同一测量或同一自述切成新 ID，仍只能算持续主张。若业务必须使用重叠滚动窗口，只能把新增增量区间且通过上述生成过程独立性检查的新材料作为确认；相邻但重叠的 24 小时窗口不能把同一批报道重复计算成持续性。

### 5.4 新颖性的时间要求

“历史上首次出现”只允许在已知档案覆盖范围内表述。正确措辞为“在本系统自某日期起的可用语料中首次出现”，不得写成“世界上首次出现”。

新增信息源或翻译能力升级会制造伪新颖性。发生这些变化后的冷启动期内，相关候选必须显示 `coverage_shift` 标志，并降低新颖性解释置信度。

### 5.5 跨语言“新词”与“新现象”

跨语言检测必须先做概念对齐，再判断新颖性：

- 音译、直译、缩写、别名、同义词和旧概念的新包装应链接到同一概念簇；
- 某语言第一次出现一个词，只能生成“词汇进入该语言”的叙事迁移候选，不能自动生成“新现象”候选；
- 翻译转载只增加传播文档数，不增加独立谱系，也不能单独证明行动者迁移；
- 只有新的本地行动者开始独立讨论、采用、反对或投入资源，才计为跨语言/地区扩散；
- 无法可靠对齐低资源语言时，保留原文、候选解释并设置 `concept_alignment_status=uncertain`，不强行合并或判新。

跨语言新颖度必须拆成 `lexical_novelty`、`concept_novelty` 和 `actor_adoption_novelty` 三项，禁止只用多语言嵌入距离输出一个结论。

### 5.6 检测器暖机与解锁

检测器不能在历史不足时假装拥有稳定基线。每个特征和 `detector_manifest` 项必须声明 `warmup_requirement`，并输出统一 `baseline_status`：

- `warming_up`：正在积累真实历史；可以生成明确标为基线受限的探索观察，但不能据此升级为 `active` 或做正式衰退/结构结论；
- `available`：达到历史长度、样本量、季节周期和覆盖健康门槛，可以按正式规则运行；
- `baseline_unavailable`：无法形成合规、可比或时间可追溯的基线，只能保存原始观察；
- `coverage_shift`：来源、分类体系、模型或口径变化使旧基线暂时不可比。

v0.1 默认暖机下限如下；实际样本量和季节周期门槛必须随检测器版本保存：

| 检测器族 | 默认解锁要求 | 暖机期允许输出 |
|---|---|---|
| 频率、速度与加速度 | 至少 28 天且覆盖 4 个可比星期周期 | 原始计数和“基线不足”观察 |
| 新词/首现 | 至少 90 天可比档案，或有明确更长外部档案边界 | 标为基线受限的探索观察，并使用 `BASELINE_WARMING_UP` |
| 扩散与现实行动 | 身份、谱系、行动去重达到质量门槛；不强制长历史 | 单次行动观察；结构扩散仍需独立确认 |
| 下降、逆转、叙事迁移、跨域关系 | 至少 90 天且覆盖健康稳定 | 方向提示，不做正式衰退/迁移结论 |
| 月级结构异常与关联破裂 | 至少 365 天，或使用经验证且时间可追溯的外部历史 | 档案诊断，不进入前瞻能力指标 |

新增来源、分类体系或模型大改后，受影响检测器必须进入 `coverage_shift`，直到使用同版本重建可比基线。30 天影子运行只能验收实时/日级检测；需要 13 周或 12 个月历史的检测器，只有积累足够真实观测龄，或拥有带同时代可用时间证据的合规历史基线时才能解锁。暖机不足本身不能被解释为世界没有变化。

## 6. 来源独立性

来源独立性不是发布者的永久属性，而是依赖“当时系统知道什么、相应观察发生时谁控制谁”的双时间判断。每次图构建和特征计算必须冻结一个 `source_registry_snapshot_id`：只使用在运行 `as_of` 已系统可见、且在对应观察时间有效的 `PublisherAccountVersion` 与 `OwnerGroupVersion`。角色、地区、所有权未知时保留 unknown 并输出上下界，禁止读取当前账号画像补值。

### 6.1 独立证据图

系统必须为 `canonical_item` 建立来源依赖图，边至少包括：

- 完全重复或近似重复；
- 明确超链接、引用或转述；
- 共同引用同一论文、公告、采访或通讯社稿件；
- 相同作者、组织、母公司或内容联盟；其中组织、母公司和联盟边必须来自冻结快照中的 `publisher_account_version_id`/`owner_group_version_id`，不得使用当前所有权；
- 时间接近且关键短语顺序高度相似；
- 同一账号网络或协调发布集群；
- 二手报道对同一匿名消息源的重复引用。

图上的共同传播根节点形成一个 `source_lineage`。同一谱系无论包含多少页面，在传播独立性中最多算一个起点；它是否形成一个或多个 `evidence_unit`，还取决于实际观察、行动者和数据生成过程，不能只靠页面聚类决定。每条依赖边还必须保存 `source_registry_snapshot_id`、两端的 `publisher_account_version_id`、适用的 `owner_group_version_id` 或 unknown、关系的 `valid_from/asserted_valid_until` 与 `system_available_at`，使后来收购或身份重分类无法改写旧图；查询终点只用 projected 字段。

### 6.2 独立性输出

每条信号必须显示下列信息，而不是只显示“共 N 篇报道”：

- 原始条目及版本数；
- 来源谱系数 `source_lineage_count` 与证据单元数 `evidence_unit_count`；
- 按冻结 `PublisherAccountVersion` 计算的独立账号/组织数，以及按冻结 `OwnerGroupVersion` 计算的所有权集团数、unknown 数和独立性上下界；
- 按冻结 `SourceRegistrySnapshot` 覆盖的语言、地区、来源类型和社会角色数；
- 是否有第一手材料；
- 是否存在无法解析的依赖关系。

这些输出必须同时返回 `source_registry_snapshot_id`、`publisher_account_version_ids[]` 和 `owner_group_version_ids[]`。2027 年发生的收购、账号角色/地区重分类、权利变化、`source_declared_update_cadence` 修订或新 `planned_poll_cadence`，不得改变已经冻结的 2026 年独立组织数、所有权集团数、actor-group diffusion、采集机会分母或特征 hash。若以 2027 年新知识重看 2026，只能创建 `retrospective_reanalysis` 新结果，并与 2026 年原结果并列。

来源质量与来源独立性是两个不同维度。五家低质量但真正独立的来源不等于高质量证据；五家高质量媒体转载同一公告也不等于五份独立证据。

不得给媒体品牌设置一个永久、全局的“真相分”。证据质量应按具体主张评估可验证性、原始记录、方法透明度、历史更正和利益冲突。第一手来源只证明“该主体发布/记录了什么”；它不会自动证明发布者关于自身效果、计划或动机的说法为真。

独立性还必须拆分为四种不同关系：

- **传播谱系独立性**：内容是否来自不同原始发布链；
- **行动者独立性**：是否有不同组织、社区或个人分别采取行动，而不是共同转述同一行为；
- **测量独立性**：统计、传感、调查或数据库是否具有不同的数据生成过程；
- **观点多样性**：不同立场是否存在；它有助于发现争议，但不等于事实独立验证。

跨圈扩散至少需要传播谱系变化或行动者迁移。单一稿件被翻译到十种语言，只能说明分发范围扩大，不能视为十个圈层独立采纳。结构性变化命题通常还需要多个独立行动实例，不能由对同一事件的多角度报道代替。行动者是否属于“新圈层”，必须比较冻结 `PublisherAccountVersion` 的地区/角色和冻结 `OwnerGroupVersion` 的控制集团；同一控制集团在多个品牌账号上的同步发布不得因品牌数增加行动者独立性。

来源本身的发现与招募原因也是独立性输入。每个声称覆盖的发现周期先激活 `SourceDiscoveryProgramManifest`，在任何目录/query 结果可读前冻结地区×语言×渠道分层、目录/query 模板、频率、随机种子、纳入概率和确定性 frame opportunity ID。每个 `SourceDiscoveryFrameOpportunity` 恰有一个 `SourceDiscoveryFrameDecision(run|skipped|failed)`；run 必须一对一引用一个 `SourceDiscoveryFrameManifest`，并满足 `program frame opportunities = run manifests ∪ skipped/failed terminals`。只为容易、准入率高或已有覆盖的格创建内部完整 frame，仍形成 program discovery gap，不能声称跨格来源发现覆盖/多样性达标。

每次实际运行的版本化目录、搜索 query、链接遍历或随机发现 frame 还要保存渠道/查询与分页或目录快照、分层、去重规则、确定性 source opportunity ID 和 inclusion receipt；frame 展开的每个规范 publisher/account/logical-stream 候选必须有唯一 `SourceDiscoveryOpportunity` 与 `SourceDiscoveryDecision(admit|reject|duplicate|failed)`。`frame_opportunity_ids = terminal_decision_opportunity_ids` 是 frame 内硬门禁；不能只为最终进入 U 的来源建决定，未入 U 的候选及拒绝原因仍留在发现分母，分页/目录缺口形成 discovery gap 并阻断单 frame 完整性/准入声明。

每个 SourceEndpointVersion 可追溯到 SourceDiscoveryDecision/RecruitmentCohort；运行时物化 `ConditioningAncestryClosure`，覆盖触发 candidate/family/query、cohort、sources、CoverageItems 与后继 candidate/family。闭包内条件化来源不能为任何后继提供 D07 扩散、独立确认或流行度升级；`C1.id != C2.id`、轻微改谓词或新 EvidenceUnit ID 都不能洗白。只有闭包外预冻结留出/随机框、无关覆盖债务招募或预登记独立性 oracle 可用。

扩散必须保存有向时间图：节点为“概念 × 本地行动者群体 × 地区/语言/角色 × 时间窗”，边表示可验证的引用传播或后续独立采纳。每个 actor-group 节点必须保存组成它的 `publisher_account_version_ids[]`、`owner_group_version_ids[]`、`source_registry_snapshot_id` 和 unknown 状态；节点地区/角色取自观察时间适用的账号版本，不得按查询当天重分类。`content_distribution`（内容被送达）与 `actor_adoption`（新行动者主动讨论或行动）必须分别计算，日报默认优先解释后者。

### 6.3 证据角色

证据单元必须标注角色：

- `primary_record`：论文、公告、法规、财报、专利、原始数据、完整讲话等第一手记录；
- `direct_observation`：可复核的现场或测量记录；
- `independent_report`：具有独立采访或调查的报道；
- `analysis`：分析与解释；
- `commentary`：观点、评论或社会反应；
- `rumor`：无法确认来源的传闻。

观点数量不能验证事实，媒体转载不能验证原始发布者的主张。系统必须分别表达“某主张被更多讨论”和“某主张被更多证据支持”。

### 6.4 主张与因果关系语义

知识层不得把来源措辞或时间先后直接写成现实因果边。关系至少区分：

- `source_claimed_cause`：某个来源声称 A 导致 B；对应展示断言只能是 `source_causal_claim`，证据蕴含只证明该来源提出了这项因果主张；
- `observed_association`：系统观察到 A 与 B 共现、相关或先后变化；它不是因果边，不得仅因强相关、先发生或预测力高而升级；
- `ai_causal_hypothesis`：AI 基于现有证据提出的可检验机制假设；对应展示断言必须是 `ai_causal_inference` 并通过 causal-premise gate；
- `mechanism_with_design_support`：已有明确研究设计、自然实验、多套独立测量或其他可复核方法支持的机制，同时保留适用范围和争议；该关系名不替代断言的 entailment/inference-support 字段。

前三类不得在摘要中被改写成“已经证明 A 导致 B”。`observed_association` 即使跨多个数据集复现，也只能先增强关联证据；除非存在预注册识别策略、可审计因果假设和相应设计支持，否则相关仍不等于因果。关系升级必须新增证据和版本事件，不能覆盖来源原本的主张；因果证据不足时系统必须说不知道。

### 6.5 主张类型、证据范围与蕴含校验

每个可展示主张必须先声明规范 `assertion_type`：

- `speech_act`：某主体说、宣布、承诺或否认了什么；
- `direct_measurement`：某范围、时间和方法下的直接测量；
- `external_world_state`：某可复核事件、行动或外部状态；
- `source_causal_claim`：明确归属于某来源的因果主张；只断言“该来源声称 A 导致 B”，不断言因果为真；
- `ai_inference`：AI 对观察的非因果解释或条件推演；
- `ai_causal_inference`：系统提出的因果机制假设；必须与一般 AI 推断分流并接受更严格的 causal-premise gate。

每条 `evidence_link` 还必须关联一个或多个 `evidence_scope_ids[]`。对应的 `EvidenceScope` 对象保存精确段落、表格单元、音视频时间码、结构化字段或测量范围，并标注其范围类型，例如 `statement_made`、`actor_intent`、`resource_commitment`、`executed_action`、`measured_outcome` 或 `causal_mechanism`。证据只能支持范围内命题；公司公告可证明“公司宣布了计划”，不能自动证明计划已执行、效果已出现或其因果解释为真。

建立 `supports` 或 `contradicts` 关系前，必须运行并保存证据蕴含兼容矩阵：

| 维度 | 必须兼容的内容 | 不兼容时的处理 |
|---|---|---|
| 证据锚点 | `span_ref`、表格单元、音视频时间码或结构化记录定位存在 | 降为 `context` 或拒绝发布事实 |
| 主语与归属 | 证据中的说话者/行动者与主张主体一致，别名映射在当时可用 | 标为归属冲突，不能支持 |
| 数值与单位 | 数字、币种、单位、数量级、分母和换算一致；换算过程可审计 | 标为数值冲突或重新计算 |
| 否定 | “没有、失败、撤销、未发现”等否定极性与主张一致 | 极性相反时为 `contradicts`，不得摘要丢失否定 |
| 模态与阶段 | 计划、可能、承诺、执行和结果不可互换 | 限定 `evidence_scope_ids[]` 所指范围，不得越级 |
| 时间与范围 | 时间窗、地区、样本、产品和适用人群一致 | 缩小命题范围或标为不确定 |
| 引用链 | 二手转述保留原说话者和共同起点 | 不能冒充新的第一手证据 |

`entailment_result` 的唯一枚举是 `entailed|not_entailed|uncertain|not_applicable`。断言门禁按类型分流：`speech_act`、`direct_measurement`、`external_world_state` 和 `source_causal_claim` 必须对当前实际发布的命题执行蕴含检查，只能使用前三个结果，不得使用 `not_applicable`；检查对象不能偷换成来源希望读者相信的更强命题。`source_causal_claim` 的可发布文本必须保留来源归属，蕴含对象是“来源 X 在范围 S 声称 A 导致 B”，通过也只证明这项言说行为，不得把结果用于支持“A 实际导致 B”。锚点缺失使用 `EVIDENCE_NOT_LOCATABLE`，不蕴含使用 `EVIDENCE_NOT_ENTAILED`，范围不匹配使用 `CLAIM_SCOPE_MISMATCH`。

`ai_inference` 与 `ai_causal_inference` 都不声称被原文蕴含，必须使用 `entailment_result=not_applicable`，同时保存 `inference_input_scope_ids[]`、指向规范 `AnalysisRun` 的 `inference_analysis_run_id`、推理规则/模型版本、适用范围、`counterevidence_analysis_run_ids[]`、已知反证、`alternative_explanations[]` 与唯一枚举 `inference_support_status=supported|unsupported|uncertain`。发布前单独执行 premise-support 门禁：前提必须由可定位观察支持，推理范围不得越过前提，已知强反证不得被遗漏；unsupported 时使用 `INFERENCE_UNSUPPORTED` 并阻断发布，而不是把推断降格伪装成事实。`entailed` 不能写入 inference-support 字段，`supported` 也不能写入 entailment 字段。

`ai_causal_inference` 还必须保存 `causal_question`、cause/outcome/time-order 范围、作为因果图节点/边或假设载体的 `causal_assumption_claim_relation_version_ids[]`、`identification_strategy`、混杂/选择偏差/反向因果检查、机制证据、负对照或敏感性分析（不适用时说明原因），以及 `causal_premise_gate_status=passed|uncertain|blocked`。只有 passed 才可发布系统因果措辞；uncertain 只能展示为待验证的因果问题，不能陈述“A 导致 B”。只有相关、共现、时间先后、Granger/预测改进或模型注意权重时，门禁不得为 passed；缺少可辩护识别策略或遗漏强替代解释时统一使用已注册的 `INFERENCE_UNSUPPORTED` 并阻断因果措辞。

`entailment_check` 必须保存各维结果、算法/人工版本和失败原因。第一手材料不是通用“高可信”标签，只对它能够直接记录的命题具有第一手地位。所有断言还必须通过 assertion type 与证据角色兼容、冲突来源不被摘要成无争议事实两道门禁。

## 7. 特征体系

### 7.1 特征数据契约

每个特征必须输出：

```json
{
  "feature_artifact_id": "fa_...",
  "name": "attention_velocity",
  "raw_value": 17.2,
  "normalized_percentile": 96,
  "interval": [12.1, 21.8],
  "window": "24h",
  "baseline_window": "28d_same_weekday",
  "baseline_epoch_id": "baseline_epoch_4",
  "coverage_stratum_version_ids": ["stratumv_language_es", "stratumv_region_latam", "stratumv_source_policy"],
  "sample_size": 41,
  "missing": false,
  "method_version": "velocity_v1",
  "evidence_unit_ids": ["ev_1", "ev_2"],
  "raw_item_version_ids": ["itemv_1", "itemv_2"],
  "source_registry_snapshot_id": "srcsnap_20260803_0000",
  "endpoint_version_ids": ["sepv_9"],
  "publisher_account_version_ids": ["pav_12", "pav_38"],
  "owner_group_version_ids": ["ogv_4"],
  "historical_rights_snapshot_ids": ["rights_20260803_0000"],
  "source_attribute_unknowns": ["owner_group:itemv_2"],
  "system_available_at": "2026-08-03T00:03:00Z",
  "as_of": "2026-08-03T00:00:00Z",
  "run_mode": "prospective"
}
```

`FeatureArtifact` 属于普通 immutable record；上例的 `as_of` 是输入知识截止，`system_available_at` 是输出可用时间。它没有 `system_from/valid_from` 或 projected closure，新的特征计算必须生成新的 FeatureArtifact。

缺失值必须保留为缺失，禁止用零替代。算法不能因为某语言或地区数据稀疏而自动判定其没有变化。

### 7.2 主要特征维度

| 维度 | 需要保留的子特征 | 解释 |
|---|---|---|
| 注意力动态 `attention` | 绝对量、速度、加速度、变点概率、峰值后衰减 | 已覆盖语料和可观察行动者中的注意记录是否异常变化；不得外推为全体人群 |
| 新颖性 `novelty` | 语义距离、新实体/关系、历史稀有度、首次出现范围 | 是否出现过去罕见的内容或组合 |
| 扩散 `diffusion` | 基于 as-of `PublisherAccountVersion` 的跨语言/地区/平台/角色数量、熵、路径、时滞及 actor-group 版本引用 | 是否从单一圈层向外传播；当前重分类不得重写过去扩散 |
| 持续性 `persistence` | 活跃窗口数、连续性、复现间隔、峰值后留存 | 是一次噪声还是持续迹象 |
| 现实行动 `action` | 意向、资源承诺、执行、结果；按行动类型计数 | 是否从讨论转化为实际行动 |
| 来源独立性 `independence` | 起点数、依赖图、第一手材料、基于 as-of `OwnerGroupVersion` 的所有权多样性与 unknown 上下界 | 支持是否真正独立；后来收购不得合并过去已冻结的集团计数 |
| 跨域汇合 `convergence` | 新跨域边、领域数、关系持续性 | 原本分离的系统是否开始耦合 |
| 叙事差异 `narrative_divergence` | 上下文、立场、行动者构成和问题框架的分布距离 | 同一概念的公开叙事是否迁移 |
| 结构异常 `anomaly` | 稳健偏离、变点、多指标同步、关系破裂 | 是否可能出现结构性变化 |
| 反证压力 `counterevidence` | 相反事实、失败、取消、不同数据集冲突 | 当前解释面临多大挑战 |
| 操纵风险 `manipulation_risk` | 协同发布、机器人、PR/SEO、单点驱动、异常账号网络 | 注意力是否可能被人为制造 |
| 数据质量 `data_quality` | 覆盖完整度、抓取健康、时间准确性、抽取可靠性 | 当前测量是否可信 |

叙事观察必须把 `mention`（被提及）、`stance`（支持/反对/中立/不明）、`intent`（计划、呼吁或承诺）与 `action`（已发生的可验证行动）分开存储和统计。任何一层增加都不能自动推断后一层增加。所有涉及地区、角色、来源类型、所有权、权利资格、`source_declared_update_cadence` 或执行性 `planned_poll_cadence` 的特征工件，必须携带同一计算所用的 `source_registry_snapshot_id` 与适用 `collection_plan_id`；缺少快照/计划/Version 引用时该特征无效，不能回退读取当前表。

### 7.3 现实行动阶梯

现实行动不能只用讨论量代理。每种行动分别记录以下阶段：

0. 讨论或预测；
1. 正式意向，例如路线图、政策草案、招聘计划；
2. 可验证的资源承诺，例如预算、合同、融资、采购；
3. 已执行，例如产品上线、工厂开工、法规生效、岗位实际增长；
4. 可测结果，例如采用量、产出、成本、行为或市场结构发生变化。

系统必须显示最高达到的阶段及各类行动的证据数量，不得只输出一个模糊的“落地分”。

招聘、专利、融资、资本开支、采购、法规和产品发布都只是现实变化的代理变量，并各有偏差：职位可以重复或不招聘，专利可以防御性申请，融资不代表采用，预算不代表执行，产品发布不代表使用。系统必须为行动创建稳定 `action_id`，对同一行动的多次报道去重，并记录“宣布者、执行者、受影响者、金额/数量、承诺时间、执行状态和结果”。阶段升级只能依据新的行动事实，不能依据讨论量增加。

### 7.4 讨论与行动的背离

下列背离本身应生成候选：

- 讨论快速升温，但投资、招聘或部署没有同步变化；
- 公开讨论减少，但专利、采购、资本开支或政策行动增加；
- 科研、产业、资本、政策、媒体或社区等可观察行动者群体之间的注意力方向相反；
- 多个来源重复同一叙事，但独立事实起点没有增加。

这类候选必须明确标注“叙事变化”还是“现实变化”，避免把舆论误当作世界本身。

## 8. 多维评分与排序

### 8.1 禁止单一总分

系统不得生成或存储 `total_score`、`importance_score`、`future_probability` 等将全部维度压缩为单一数字的字段。原因是：

- 不同信号类型的可比维度不同；
- 隐含加权会重新制造不可见的信息过滤；
- 高新颖低置信和低新颖高行动的信号都可能值得查看；
- 单一分数会掩盖数据缺失、来源依赖和操纵风险。

信号必须以向量形式保存：

```json
{
  "attention": 92,
  "novelty": 88,
  "diffusion": 47,
  "persistence": 35,
  "independence": 61,
  "anomaly": 79,
  "action_stage": 1,
  "counterevidence_level": "medium",
  "manipulation_risk": "high",
  "data_quality": "medium"
}
```

其中 0–100 数值表示同一分层、同一时间尺度、同一方法版本内的分位位置，不表示未来发生概率。

### 8.2 信号类型准入与核心维度

以下是 v0.1 初始规则，阈值必须配置化，只能依据开发时间段、锁定验证段和前瞻影子运行调整；不得在同一著名历史案例上反复调优后报告效果：

| `signal_type` | 默认准入条件 | Pareto 核心维度（仅 2–3 个） | 默认规则 ID |
|---|---|---|---|
| `emergence` | 新颖性达到本分层第 90 分位，或出现当时档案未见的实体关系；至少一个证据单元 | `novelty`、`independence`、`persistence` | `emergence_rank_v1` |
| `acceleration` | 注意力速度或加速度达到第 95 分位，并在断开的确认样本中复现；高可信重大行动可单独触发观察 | `attention`、`persistence` | `acceleration_rank_v1` |
| `diffusion` | 进入至少三个已注册覆盖格或形成可验证行动者迁移，且包含至少两个独立证据单元 | `diffusion`、`independence`、`persistence` | `diffusion_rank_v1` |
| `real_world_action` | 至少出现一项可验证的阶段 2 以上行动；阶段 1 只能进入观察 | `action`、`independence`、`persistence` | `action_rank_v1` |
| `convergence` | 至少两个此前弱相关领域出现新关系，并在独立证据单元中复现 | `convergence`、`novelty`、`independence` | `convergence_rank_v1` |
| `narrative_shift` | 上下文、角色或立场分布改变，且排除来源结构和模型版本变化 | `narrative_divergence`、`diffusion`、`independence` | `narrative_rank_v1` |
| `decline_or_reversal` | 采集健康正常，负向变化跨断开的确认样本持续，或存在可验证的取消/撤回行动 | `attention`、`persistence`、`action` | `decline_rank_v1` |
| `structural_anomaly` | 稳健变点或多个独立指标同步偏离；必须显示替代解释 | `anomaly`、`independence`、`convergence` | `anomaly_rank_v1` |

未达到准入条件的候选仍可保存在候选库中，不应删除。

### 8.3 栏目内排序与约束优先级

排序按以下流程执行：

1. 法律、许可、隐私、安全与时间可见性硬约束；
2. 数据健康、处理水位、证据可追溯和检测器暖机约束；
3. `signal_types[]` 各自的准入规则；
4. 覆盖矩阵 `allocation_lane`、覆盖债务和集中度约束；
5. 对每个目标 `surface_section` 创建独立 `selection_decision`，应用其中唯一的 `ranking_rule_id`；
6. 每个信号类型预登记核心维度上的迭代 Pareto 前沿；
7. 同一配额桶内按规则声明的维度顺序、置信和触发输入的 `information_arrival_at` 排序；不得用候选或派生物的 `system_available_at` 充当新鲜度；
8. 所有值仍相同时，使用稳定 `candidate_id ASC` 作为最终确定性 tie-break。

约束优先级不得被后续低优先级步骤覆盖。操纵风险通常作为独立标识而非静默过滤；但明确垃圾、重复、无权限内容和安全攻击可在第一层阻断。稳定 ID tie-break 只用于可复现，不代表更早 ID 更重要。

不同产品栏目不得合并成一个总榜。产品可以提供“今日信号集合”，但必须保留 `surface_sections[]`、唯一 `allocation_lane` 和选择原因。

为避免高维 Pareto 前沿退化为“几乎所有候选都不可支配”，每个信号类型只使用上表 2–3 个预先登记的核心维度计算前沿。数据质量、操纵风险和反证压力作为独立约束与标注，不通过增加维度来变相放宽入选。

### 8.4 热点栏目

热点使用规模镜头，按绝对讨论规模、跨区域覆盖、来源独立性和实时增长分别展示。它必须同时给出可观察分母与覆盖边界，不能将样本内规模写成“全世界的人都在关注”。热点排名不得占用弱信号或盲区探索配额，探索配额也不得改写热点规模。

### 8.5 选择轨迹

每次候选选择必须生成机器可读的 `selection_trace`，至少包括：

- 哪个检测器在何时、哪个分层触发；
- `signal_types[]` 及通过和未通过的类型准入规则；
- 唯一 `allocation_lane`、仅审计用的 `eligible_allocation_lanes[]` 和预算占用次数；
- `surface_sections[]` 及每个栏目的 `ranking_rule_id`；
- 所在覆盖配额桶、该桶容量与桶内位置；
- 是否位于 Pareto 前沿；
- 是否通过盲区探索名额入选及随机种子；
- 去重、合并、操纵检查和数据健康检查结果；
- 最终入选、未选或降级的 `selection_reason_codes[]`；
- 规则、阈值、`coverage_policy_version`、`source_registry_snapshot_id`、`scope_snapshot_id`、`coverage_stratum_version_ids[]` 和排序代码版本；
- 最终 tie-break 字段和值。

系统必须保留每期“准入但未展示”的候选及原因，用于回答“为什么看到了 A 而没看到 B”。人工置顶、隐藏或修改必须进入独立的 `editorial_override` 日志并使用 `EDITORIAL_OVERRIDE`，不能伪装成算法结果。

## 9. 证据、反证与可证伪性

### 9.1 信号命题

每条信号必须有一个中性、可检验的命题，格式建议为：

> 在【范围】内，【对象】的【可观察属性】相对【时间基线】出现【方向与类型】变化。

示例：

> 在过去四周的东亚半导体招聘与采购数据中，面向先进封装的资源承诺相对过去一年基线持续上升。

禁止使用“将颠覆世界”“下一个万亿市场”等不可证伪和煽动性措辞。

### 9.2 证据链接

所有展示层事实必须链接到一个或多个 `observation_id`，观察再链接到 `evidence_unit_id` 和权限化 `provenance_ref`。`provenance_ref` 可以解析为获准快照、受限内部记录、许可内片段、结构化数据定位、原始链接或删除墓碑；访问检查必须在服务端执行。系统不要求所有用户、模型或运行环境都能读取全文，也不得通过引用字段绕过来源许可或隐私策略。AI 推断必须标注为推断，并列出其使用的观察。

权限不是一次性检查。采集、抽取、模型出站、训练、派生持久化、候选选择、报告发布/渲染和用户检索必须分别依据当时最新 policy 与 rights snapshot 重新授权，并保存 `purpose_authorization_id`、资源版本 hash、目标处理方、`checked_at`、`expires_at` 和 `revocation_epoch`。目的不获准时只使用第 17.1 节对应的 `PURPOSE_ACQUIRE_DENIED`、`PURPOSE_EXTRACT_DENIED`、`PURPOSE_MODEL_DENIED`、`PURPOSE_TRAIN_DENIED`、`PURPOSE_SIGNAL_DENIED`、`PURPOSE_DISPLAY_DENIED`、`PURPOSE_PREVALENCE_INELIGIBLE` 或 `MODEL_TRANSFER_FORBIDDEN` 原因码。

删除或撤权必须递增 `revocation_epoch`，取消或 taint 仍在途的旧 epoch 任务；任何受污染输出不得持久化、选择或展示。发布原子提交前必须再次核对最新 epoch，不一致时使用 `REVOCATION_RACE_BLOCKED` 并中止提交；读时投影始终覆盖旧缓存。若撤权发生在外部模型请求已经发送之后，系统不得声称传输已撤销，而应阻断后续持久化与展示、执行供应商删除/不保留流程，并记录不可逆暴露范围。

证据关系必须标注为：

- `supports`：直接支持命题；
- `contradicts`：直接反驳命题；
- `context`：提供背景但不能验证命题；
- `uncertain`：关系不明确或抽取置信不足。

每个关系还必须保存 `assertion_type`、`evidence_scope_ids[]`、`entailment_result`、条件适用的内嵌 `entailment_check` 和执行该检查的 `entailment_analysis_run_id`、访问级别和红删状态；具体 `EvidenceScope` 再保存 `span_ref` 或等价结构定位。事实与来源主张只有通过第 6.5 节兼容矩阵才能作为事实卡片的 `supports` 或 `contradicts`；`ai_inference` 与 `ai_causal_inference` 必须改走 premise-support/反证门禁，后者另走 causal-premise gate，不得创建假装“原文蕴含推断”的证据边。`source_causal_claim` 的 supports 边只能支持“某来源提出该因果说法”，不能复用于支持现实因果关系。

### 9.3 主动寻找反证

信号进入 `watch` 后，系统必须自动生成反证查询，至少检查：

- 相同指标是否存在下降或相反地区；
- 宣布的计划是否被取消、延迟或未执行；
- 独立数据集是否复现；
- 注意力增长是否仅由一个账号、一次发布或付费传播造成；
- 是否存在更简单的解释，例如季节性、改名、法规截止日或采集变化；
- 支持者和反对者是否都引用同一个事实起点。

没有找到反证不等于反证不存在。只有当覆盖充分时，才可以将“未观察到”作为有限证据。

### 9.4 后续观察条件

每条活跃信号必须维护：

- `would_strengthen[]`：哪些未来可观察事实会增强命题；
- `would_weaken[]`：哪些事实会削弱命题；
- `would_falsify[]`：哪些事实会直接证伪命题；
- `next_check_at`：下一次检查时间；
- `watch_metrics[]`：后续跟踪的数据与来源。

这些字段必须具体到可测事实，不得写成“继续关注发展”。

### 9.5 `report_claim` 契约

日报与实时卡片中的每个独立事实、来源主张或 AI 推断都必须拆成 `report_claim`，至少包含：

```text
report_claim_id
report_edition_id | global_radar_snapshot_id  # 恰有一个
claim_generation_unit_id / claim_generation_decision_id
presentation_event_id
claim_container_identity_id / claim_container_kind=record / claim_container_type = ReportEdition | ReportCardPlacement | GlobalRadarSnapshot | RadarCardPlacement
claim_order
text
canonical_proposition_payload / canonical_proposition_hash / canonical_text_hash
assertion_type = speech_act | direct_measurement | external_world_state | source_causal_claim | ai_inference | ai_causal_inference
epistemic_status = asserted | disputed | retracted | unknown
subject_entity_version_ids[] / predicate / object
time_scope / geographic_scope / population_scope
quantity{value, unit, currency, denominator} | null
observation_ids[]
signal_evidence_link_ids[] / counterevidence_signal_evidence_link_ids[] / evidence_scope_ids[]
provenance_refs[]
entailment_result / entailment_check / entailment_analysis_run_id | null
inference_input_scope_ids[] / inference_analysis_run_id | null
inference_support_status / counterevidence_analysis_run_ids[] / alternative_explanations[]
causal_question / causal_assumption_claim_relation_version_ids[] / identification_strategy | null
causal_premise_gate_status / confounder_checks[] / reverse_causality_check | null
observation_confidence / interpretation_confidence
analysis_run_id | null
system_available_at / as_of / run_mode
content_projection_status = available | content_removed_by_policy
```

一个句子包含多个可独立真假判断时必须拆分。断言是事实、来源主张还是 AI 推断只由 `assertion_type` 表达，不能混入 `epistemic_status`；后者只表达跨证据认识状态。事实或来源主张必须有非 `not_applicable` 的蕴含结果；`source_causal_claim` 必须保留来源归属，蕴含通过不等于因果成立；`ai_inference` 与 `ai_causal_inference` 必须为 `entailment_result=not_applicable` 且通过 premise-support/反证门禁，后者还须通过 causal-premise gate；`unknown` 不能被语言模型补成结论。报告重新生成时在新 `ReportEdition` 下、雷达刷新时在新 `GlobalRadarSnapshot` 下创建新的 `report_claim_id`，不覆盖旧 `ReportClaim`。

ReportPipelineManifest/RadarPipelineManifest 为每类 container 冻结 claim-slot schema。系统先确定性物化 ClaimGenerationUnit，再为每个 unit 写唯一 terminal ClaimGenerationDecision；required slot 不允许 not_applicable，outcome=claim 时恰有一个 ReportClaim，selected card 和日报/雷达概览至少一个 required claim。缺 unit/decision/claim、零 claim 真空通过或跨 container 引用均返回 `CLAIM_COLLECTION_INCOMPLETE` 并阻断整个 presentation event。

所有用户可见或辅助可访问的动态语义文本必须进入 PresentationRenderPlan。每个 PresentationContentUnit 按 channel/locale/container/order 登记为 `claim_ref`、带精确 version/scope/rights/hash 的 `source_text_ref`，或不含动态语义变量的 `controlled_template|static_ui`；标题、摘要、why-now、caption、tooltip、alt/ARIA、折叠内容、Markdown/HTML、通知和导出均不得旁路。最终 DOM/序列化输出的 unit/ref/hash 与 plan 双向不相等时返回 `UNAUDITED_PRESENTATION_CONTENT` 并拒绝发布。

`claim_ref` 实际引用一个 `ClaimExpressionVariant`，而不是让客户端直接翻译 ReportClaim.text。每个 required locale/channel/variant role 都冻结表达 hash、TranslationArtifactVersion/ModelOutputArtifact 与 semantic-equivalence decision；否定、模态/“可能”、来源归属、AI 推断标记、数值/单位/分母及范围任一丢失均返回 `CLAIM_EXPRESSION_NOT_EQUIVALENT`。视觉正文、屏幕阅读器、tooltip、通知和导出可有不同措辞，但必须分别通过相同 canonical proposition 的语义槽门禁。

claim 附近的 `source_text_ref` 必须引用 `ClaimCitation`，保存关联 ReportClaim、exact source version/metadata field/EvidenceScope、AuthorizedContentScope/PurposeAuthorization、locale/hash 与 `citation_role=entails|source_asserts|context|contradicts`。只有 entails/source_asserts 可渲染“证据/来源主张支持”标签；context/contradicts 明示角色。合法但无关的来源 B 标题或引文挂到 claim A，或把 context 标成 evidence，均以 `CITATION_CLAIM_MISMATCH` 阻断。

无 claim 的原始资料列表改用 `RawSourceListingReference`：它绑定同 presentation event 的 ReportItemPlacement、exact source version/metadata field、AuthorizedContentScope/PurposeAuthorization、locale/hash，只能显示“原始资料”，不得含 report_claim_id 或 evidence/support 标签。SourceTextRefContentUnit 在 ClaimCitation 与 RawSourceListingReference 之间恰选一个；nullable ClaimCitation 或把 raw listing 塞入 citation role 均不合法。

## 10. 置信标注

### 10.1 三种不同判断

界面与 API 必须分开表达：

1. **观察置信 `observation_confidence`**：基础事实和计数是否可靠；
2. **解释置信 `interpretation_confidence`**：现有观察是否足以说明一种真实变化；
3. **未来含义 `future_implication`**：仅作为条件推演，不给概率，不并入前两项置信。

### 10.2 置信等级

| 等级 | 观察置信的典型条件 | 解释置信的典型条件 |
|---|---|---|
| C0 数据不足 | 时间、来源或采集健康不明 | 只有模糊关联，替代解释未检查 |
| C1 初步 | 单一证据起点，或抽取仍需复核 | 新颖但仅一个窗口、一个圈层 |
| C2 有支持 | 多个独立起点或一份可复核第一手材料 | 跨窗口复现，并处理主要替代解释 |
| C3 较稳健 | 多来源、多层、时间与数据质量可靠 | 现实行动或多指标一致，反证检查后仍成立 |

置信等级不能由简单平均分生成。升级必须满足规则，降级必须记录原因。存在高质量冲突证据时应标记 `disputed`，不得通过平均抵消冲突。

每个置信结论必须附：

- `confidence_reasons[]`；
- `uncertainty_reasons[]`；
- `missing_evidence[]`；
- `last_reviewed_at`；
- 自动判定还是人工复核。

“高变化强度、低解释置信”是合法且重要的状态，尤其适合早期雷达。

## 11. 信号生命周期

### 11.1 状态

| 状态 | 定义 |
|---|---|
| `candidate` | 任一检测器触发，尚未完成基本证据与管道健康检查 |
| `watch` | 命题成立、原始证据可追溯，值得持续观察，但证据仍弱 |
| `active` | 在时间、来源或层级上复现，变化仍在发展 |
| `established` | 变化已得到稳健证据或进入可测的现实执行阶段；不等于其未来影响已知 |
| `fading` | 注意力或行动减弱，尚不足以认定命题错误 |
| `falsified` | 命题的关键可证伪条件被满足，或原始证据被证明错误 |
| `archived` | 达到归档条件，不再进入常规日报，但保留完整历史 |
| `reactivated` | 归档或衰退后出现新的独立变化，应产生新周期并链接旧信号 |

### 11.2 状态转换

- `candidate → watch`：完成溯源、命题生成、基础管道健康检查，并至少有一个可访问原始证据单元；
- `watch → active`：在与检测样本断开的确认窗口中复现，或出现第二个独立证据单元/新的行动者扩散层/阶段 2 以上现实行动；重叠滚动窗口中的同一材料不得自我确认；
- `active → established`：关键观察跨来源、跨时间稳定，或达到预先定义的现实验证条件；
- `watch/active → fading`：经覆盖校正后，关键指标连续低于活跃条件；
- `any → falsified`：满足明确的证伪条件；
- `fading/falsified → archived`：经过配置化冷却期且无新证据；
- `fading/archived → reactivated`：出现新的独立证据、变点或行动周期；新触发可以冻结新的 `candidate_id` 并链接旧候选，但不得修改、复用或移除旧候选及其评估分母。

除非出现范围匹配、蕴含校验通过的第一手证伪或重大行动证据，状态转换默认要求检测样本与至少一个不重叠确认样本，以避免抖动。不同时间尺度使用不同冷却期，具体值写入版本化配置。

### 11.3 只追加历史

状态、命题、分数、证据、反证、合并、拆分和人工修订都必须以事件日志追加，禁止覆盖旧版本。每次日报必须能够还原当时看到的信号版本。

“被证伪”和“消退”是系统学习资产，不得作为失败记录删除。后续模型应分析它们为何被触发、何时可以更早降级，以及哪些检测器容易产生噪声。

追加保存服从合法删除、隐私与访问撤销义务。不得以“研究历史”为由保留无权继续处理的内容。

合规删除必须区分：

- `redaction`：仅移除无权显示或处理的具体字段、片段、个人标识、嵌入和派生摘要，并生成版本化红删事件；
- `tombstone`：正文或对象必须删除时，仅保留法律允许的非内容标识、删除原因类别、时间和审计哈希；墓碑不能继续充当支持证据；
- `provenance_access_revoked`：证据仍合法存在于受限区，但当前主体无权解析 `provenance_ref`；界面只显示权限状态；
- `EVIDENCE_CENSORED`：评估所需证据或结果因删除、撤权或不可观察而无法判断时使用的评价原因码；候选仍保留在冻结评估 cohort 及总数中，并单独报告信息性删失。成败率必须使用预登记的删失处理，不能把它自动记为误报、命中或静默移出样本。

政策删除使用 `DELETED_BY_POLICY`；若同时造成评价不可判断，再另加 `EVIDENCE_CENSORED`，两者不得互为同义状态。红删必须递增 `revocation_epoch`，并级联到正文、片段、向量、缓存、搜索索引、模型训练材料、`report_claim` 和可识别关系。当前信号以新版本重新计算；旧报告当前投影设置 `content_projection_status=content_removed_by_policy`，仅保留合法墓碑、项目顺序和不含内容的随机 receipt/HMAC，低熵内容不得保留可公开枚举的裸 hash。前瞻评估同时保留删失原因、发生时间和候选占位。

## 12. 操纵与偏差防御

### 12.1 需要检测的操纵

- 新闻稿、通讯社稿件或 SEO 农场的大规模转载；
- 机器人、批量新账号、同步文案和协调转发；
- 付费媒体、网红投放、品牌公关和政治宣传；
- 单个权势人物造成的注意力峰值；
- 同一所有权集团跨品牌重复发布；
- 翻译转载被误判为跨语言独立扩散；
- 搜索引擎或平台榜单反馈循环；
- 数据供应商改变口径造成的伪变点。
- 原始网页、PDF、帖子或附件中试图命令模型忽略规则、泄露数据、调用工具或改变评分的提示注入。

### 12.2 防御措施

系统必须：

1. 先按证据起点去重，再计算讨论与独立支持；
2. 同时显示“传播规模”和“独立事实增长”；
3. 检测时间同步、文本相似、账号网络和所有权集中；
4. 为单一来源、单一平台和单一所有权集团设置展示上限；
5. 将操纵风险作为独立字段，不用隐藏权重悄悄降分；
6. 对高风险但真实重要的传播现象保留卡片，并明确其可能代表“宣传活动”而非现实变化；
7. 记录采集规则、平台 API 变化、翻译模型升级和分类器升级；
8. 定期用人工样本审计非英语、低资源地区和小众领域的误分类。

所有外部内容都必须被视为不可信数据，而不是系统指令。抽取服务必须使用结构化输出和最小工具权限；不得执行网页脚本、文档宏、内嵌命令或内容指定的外部调用；不得让原文改变系统提示、覆盖矩阵、检测阈值或证据关系。提示注入命中的原文仍可作为“有人发布了这段内容”的证据，但其中的命令没有执行权限。单靠文本分隔符不构成安全边界，必须在运行时实施权限隔离与允许列表。

### 12.3 系统性偏差

覆盖与排名审计至少检查：

- 英语及高收入地区是否占据不成比例的名额；
- 新闻媒体是否压制论文、政策、招聘、专利和基层记录；
- 高频发布者是否因数量优势被重复放大；
- 可数字化领域是否被误认为比难数字化领域更重要；
- 模型是否把“不熟悉”误判为“新颖”；
- 审查、网络接入差异或平台封闭是否造成“沉默即不存在”的错觉；
- 用户反馈是否越界进入全球雷达。

所有覆盖缺口必须作为数据质量说明展示，不能通过模型补写。

## 13. 前瞻评估、运行回放与档案诊断

历史回测主要用于发现管道错误、比较检测器和压力测试，不是系统提前发现能力的最高等级证据。能力评估优先级必须是：

1. 预先登记规则后的前瞻影子运行；
2. 冻结输出的持续前瞻评估；
3. 使用当时可用对象和冻结工件的操作回放；
4. 具有同时代捕获证据的档案回放；
5. 使用后来模型、别名、聚类或知识的回顾性重分析。

每次规则或阈值修改都应登记生效时间、理由和预期影响。修改前已经产生的前瞻结果不得重写；修改后形成新的评估周期。

### 13.1 运行模式与操作回放

每个 `analysis_run` 必须且只能声明一个 `run_mode`：

| `run_mode` | 允许的输入 | 用途 | 能否支持发现能力声明 |
|---|---|---|---|
| `prospective` | 运行当时真实可用的数据与模型 | 影子运行或生产运行 | 可以，是最高等级证据 |
| `operational_replay` | 上线后真实保存且截止 T 已可用的输入、特征、AnalysisRun 输出版本和选择工件 | 复现当时系统状态 | 不替代前瞻评估，只能证明可复现性 |
| `archive_replay` | 具有独立同时代捕获时间证据的历史档案 | 历史机制诊断 | 不可以；无可靠捕获时间时连时间切片能力也不能声称 |
| `retrospective_reanalysis` | 今天使用新模型、新别名、新聚类或新知识分析旧档案 | “今天如何重看” | 不可以，只能诊断和研究 |

`operational_replay` 必须模拟某一历史时刻真正可获得的信息：

1. 设定截止时间 `T`；
2. 原始版本只读取 `version_available_at <= T` 的版本；其他记录按 05 time-profile registry 要求其 system-availability time `<= T`，只有登记的 bitemporal version 再检查 `system_from <= T < projected_system_to(T)`，standalone snapshot 还检查冻结/成员清单；任何投影只使用 T 时已可见事件；
3. 使用当时已经冻结的 `SourceRegistrySnapshot`、采集状态、实体别名、概念/事件聚类、基线、AnalysisRun 输出版本和算法配置；来源分层、actor-group 扩散、所有权独立性和权利历史资格只能解析该快照引用的 PublisherAccountVersion、OwnerGroupVersion 与 rights snapshot，采集机会分母只能解析同一快照引用的 CollectionPlanManifest.`planned_poll_cadence`；
4. 在看未来标签前生成候选、卡片和状态快照并写入不可变记录；
5. 到达未来评估窗口后，才添加结果标签；
6. 按相同时间步推进，禁止用完整历史重新聚类后再投射回过去；
7. 查询层强制过滤 T 以后才出现的别名、来源依赖、事件合并、证据关系、人工纠错、来源版本和来源注册表快照。

回放执行本身仍须按当前权利 policy/epoch 重新授权；若 2026 年历史快照中当时获准的内容在当前已撤权，系统保留旧输出和不可变审计事实，但当前回放不得读取或展示该内容，并按删除/删失规则处理。这里的当前授权门禁不能反向改写 2026 年 `rights_snapshot_id` 或声称当时已经撤权。

### 13.2 禁止的泄漏

- 使用后续修订过的文章正文、发布日期或统计数据；
- 用未来形成的主题词表、实体别名或知识图谱反向识别过去；
- 用最终热门事件挑选回测样本后声称具有普遍召回能力；
- 使用全时间段归一化、IDF、聚类中心或训练/测试混合嵌入；
- 用未来文章中的引用关系证明过去来源独立；
- 用当前 publisher role、region、owner、rights 或 cadence 重新计算过去分层、actor-group diffusion、所有权独立性、资格或采集机会分母；
- 把 2027 年收购、账号角色/地区重分类、权利或节奏修订投射进 2026 年 `operational_replay`；
- 调整阈值直到命中已知案例，再在同一案例上报告效果；
- 忽略当时尚未被系统抓取的资料，却把其发布时间当成已知时间。

### 13.3 模型知识泄漏

使用在回测截止时间之后训练的语言模型，可能隐含知道后续事件。严格回测应使用时间边界可说明的模型，或只用截止时间内语料训练/拟合的统计与表示方法。

只要语言模型的训练截止时间晚于回测时点，其结果就只能用于诊断抽取、聚类、界面和分析流程，即使提示词要求它“忘记未来”，也不得计入提前量、召回率或置信校准等能力指标。此类运行必须标注为 `retrospective_reanalysis`；若只是读取具有同时代捕获证据且不使用未来模型的历史档案，才可标为 `archive_replay`。语言模型可以格式化历史可用证据，但不得把参数知识补充成当时存在的事实。

### 13.4 重分析版本

新模型可以重新解释历史原始档案，但必须创建 `run_mode=retrospective_reanalysis` 的新 `analysis_run`，并同时保留：

- `as_of`：模拟的信息截止时点；
- `reanalyzed_at`：实际重分析时间；
- `run_mode`：`prospective`、`operational_replay`、`archive_replay` 或 `retrospective_reanalysis`；
- 当时原始输出与新输出的并列差异；
- 模型、提示词、抽取器、`baseline_epoch_id`、`source_registry_snapshot_id`、`scope_snapshot_id`、`coverage_policy_version` 与 `coverage_stratum_version_ids[]`。

重分析不得覆盖当时日报，也不得把新模型更早“看懂”历史材料算成当时系统已经发现。

### 13.5 冻结工件与确定性边界

每个报告和候选运行必须冻结并内容寻址保存：

- `raw_manifest_hash` 与输入对象版本；
- `source_registry_snapshot_id` 及实际使用的 `endpoint_version_ids[]`、`publisher_account_version_ids[]`、`owner_group_version_ids[]`、历史 `rights_snapshot_id`、描述性 `source_declared_update_cadence` 与执行性 `collection_plan_id/planned_poll_cadence`；
- `analysis_run_ids[]` 以及每个 AnalysisRun 按规范对象类型分列的输出 Version ID 与内容 hash：翻译、抽取、分类、摘要等实际使用结果；
- `feature_artifacts[]`：用于候选和排序的完整特征值、缺失状态和基线；
- `candidate_manifest`、`selection_decisions`、配置、随机种子和代码版本；
- `report_claims` 与最终渲染工件。

“确定性重放”只承诺：在相同候选清单、冻结来源注册表/特征工件、选择策略和随机种子下，重新执行选择逻辑得到相同候选 ID、栏目顺序和原因码。它还必须复现相同 actor-group 节点、扩散/独立性值和特征 hash；实现不得把冻结的来源版本引用解析成当前记录。它不承诺重新调用随机或已退役模型后逐字生成同一翻译、抽取或摘要；这些内容通过冻结的 AnalysisRun、具体输出 Version ID 与内容 hash 复现。重新计算产生的新输出属于新的 `AnalysisRun`，必须做漂移比较。

### 13.6 回测集

回测集必须包含：

- 后来被确认的重要变化；
- 曾快速升温但后来消退的主题；
- 被公关或协同传播制造的伪趋势；
- 非英语、低曝光地区和小众领域案例；
- 讨论先行、行动滞后的案例；
- 行动先行、讨论滞后的案例；
- 下降、逆转和叙事迁移案例；
- 随机时间段的无事件对照组。

只使用成功案例会产生幸存者偏差，因此不合格。

### 13.7 前瞻评估台账

从首日影子运行开始，系统必须维护不可变的前瞻台账。每个候选首次冻结时保存不可变 `candidate_id`、`candidate_frozen_at`、`proposition_family_id`、family rule、`candidate_emission_key`、命题、初始检测证据/输入 universe、状态、特征、数据截止时间、后续观察条件、`evaluation_protocol_version` 和协议 hash，并统一在 7、30、90、180、365、730 天按预先声明的规则追加结果。候选 commitment 之后出现的 evidence/detector 只能进入 CandidateTriggerEvent，绝不回写上述冻结字段。merge、split、reactivate 或 Signal 映射不改变 candidate-level 分母；报告同时给 candidate-level 和预注册 family-level 结果。结果至少区分独立复现、现实行动、持续但未确认、消退、证伪、操纵与数据不足；删失只使用 `EVIDENCE_CENSORED`，数据不足只使用 `DATA_INSUFFICIENT`，不能压成“预测成功/失败”。

系统、绝对热门、分层随机、传统编辑、champion 与 challenger 不能只有“配置相同”的声明。EvaluationProtocolVersion 在任何 arm 数据可读前冻结 `EvaluationArmManifest`，列出每个 arm 的实现/规则版本、eligible input universe、K、输出 schema、随机种子和确定性 generation key。每个 `arm × eligible input` 先物化 `EvaluationArmGenerationUnit`，再写唯一 `EvaluationArmGenerationDecision(output|no_output|failed)`；每个 arm 在 outcome reveal 前形成内容寻址的 `EvaluationArmOutputSnapshot`，冻结完整有序输出及对应 evaluation subject/candidate IDs。`arm generation terminals = arm output projection` 且 `arm output members = EvaluationObligations = EvaluationResults` 是能力比较硬门禁；不能只保存基线中表现差的输出，或只为系统 arm 创建复核义务。所有 arm 必须复合绑定同一协议、CorpusScopeSnapshot、cutoff/watermark、rights、质量门槛、K 和 OutcomeFrame；任一 arm 缺 unit、output、obligation 或 result 时，比较能力声明和版本晋升均 blocked。

每个 horizon 固定 `outcome_as_of = candidate_frozen_at + horizon`，并在该时点冻结 `evaluation_corpus_snapshot_id`。快照必须是内容寻址、不可变且完全物化的 ID 清单，至少保存 `snapshot_frozen_at`、`raw_item_version_ids[]`、按具体对象类型分列的派生 Version ID 清单、`evidence_unit_ids[]`、`source_registry_snapshot_id`、`rights_snapshot_ids[]`、`scope_snapshot_id`、`coverage_policy_version`、`coverage_stratum_version_ids[]`、每项内容 hash、计数、`snapshot_manifest_hash`、内嵌内容 receipt 和每个输入的 Merkle inclusion proof；它不是 SQL、搜索表达式、保存的过滤器或可在执行时重跑的查询。清单只能包含 `version_available_at <= outcome_as_of` 的原始版本，以及在该时点可见且由这些输入导出的派生版本；来源角色/地区/所有权与 cadence 只能来自该时点冻结的来源注册表快照，覆盖边界只能来自冻结的 CoverageStratumVersion。

每个 `(candidate_id,evaluation_protocol_version,horizon)` 确定性生成唯一 EvaluationObligation，并分别恰有一个 `EvaluationSnapshotDecision(snapshot|missed)` 和一个 `EvaluationResult`；两者均 `UNIQUE(obligation_id)` 并复合绑定同 candidate/protocol/horizon/ledger。并发 snapshot/missed 或相反结果至多一个提交，缺失/矛盾时 gate blocked，不能择优读取成功行。

OutcomeFrameManifest 必须绑定 EvaluationProtocolVersion，并在 cohort 开始、首次 candidate/arm 数据访问及首个候选冻结三者最早者之前完成外部锚定；它冻结现实结果机会 universe、outcome definition、确定性生成规则和隐藏来源 frame，并证明 transitive candidate/selection/delivery lineage count=0。只写“独立于 candidate”或在正式揭盲前才创建不构成独立：看到候选命题后定制一个完整 frame 同样是条件化。每个机会有唯一 OutcomeGenerationDecision(outcome/no-outcome/unknown/failed)，然后才创建 OutcomeUnit/Cluster 和 CandidateOutcomeLink；若 10 个 frame outcomes 只链接 1 个，coverage=1/10。没有满足上述时序与零 lineage 证明的独立 frame 时禁止 outcome coverage/recall；共享结果仍按 cluster 计算 n_eff 与稳健区间。

系统的展示、通知、对话建议或公开报告可能改变后续世界，而不只是观察它。OutcomeFrameManifest 必须冻结每类 outcome 的因果行动者/受影响组织生成规则；对每个 `OutcomeUnit × CandidateOutcomeLink × causal_actor_or_action` 先确定性物化 `OutcomeActorExposureUnit`，再写唯一 `OutcomeActorExposureDecision(unexposed|possibly_exposed|exposed|unknown)`，并以冻结 delivery/publication/已知外部传播 lineage 核对该行动者是否在行动前接收或接触候选。`actor units = actor terminals = exposure lineage subjects` 是硬门禁；不能只挑未暴露的签字人而漏掉收到提醒并发起行动的决策者。已知 delivery 不是完整曝光证明，无法排除、行动者漏建或 lineage 不完整时不得默认 unexposed。

CandidateOutcomeLink 的 `intervention_exposure_status` 只能由完整 actor decisions 按冻结最坏情形 reducer 投影：任一可归因行动者为 exposed 则 link=exposed；无 exposed 但任一 possibly_exposed/unknown/缺失则相应为 possibly_exposed/unknown；只有全部相关行动者可证明 unexposed 才能投影 unexposed。纯“提前发现/预测”能力只使用预注册 shadow/holdout 或通过该全量门禁的结果；`exposed|possibly_exposed|unknown` 进入最坏—最好敏感性并单列为 decision-support/intervention outcome，不能把因提醒而发生的采购、采用或发布当作被动预测命中。

每次 release/version 在 cohort 前冻结 `CapabilityClaimFamilyManifest` 的 protocol×metric×horizon×subgroup×look universe 与共享 multiplicity budget；每个机会有唯一 CapabilityClaimDecision。对外陈述/GateDecision 必须引用它并披露 sibling results，不能从 20 个合法协议中只发布唯一显著者。

复核作业可以晚执行，但只能逐 ID 读取该清单和协议冻结的评估工具，验证清单、receipt、hash 与 inclusion proofs 后另存 `evaluation_executed_at`；不得重新检索、补齐替代版本或让晚作业看到 horizon 后出现的结果。快照 manifest hash 必须在冻结时作为 ledger entry 入链，并保存 `snapshot_anchor_deadline_at = outcome_as_of + 5 分钟`、外部证明的 `snapshot_anchored_at` 与 receipt；这证明的是该清单当时已存在，而不是晚作业的查询结果。清单中的对象后来因删除/撤权不可读时按 `EVIDENCE_CENSORED` 处理，不能用当前搜索结果替换。若快照未在 deadline 前完整形成并锚定、只保存了查询定义或清单/inclusion proof 不完整，写入 `MISSED_EVALUATION_SNAPSHOT`，不得事后重建并冒充该 horizon 结果。

候选冻结时保存并承诺 `detection_evidence_unit_ids[]`、`detection_source_registry_snapshot_id` 和其谱系/行动者/数据生成过程；horizon 复核只能读取这份冻结 detection 清单，不能把后来 CandidateTriggerEvent 的证据重新分类为“当初检测证据”。验证证据不能由 EvaluationResult 中自由填写一个有利数组：按 EvaluationProtocolVersion，对 EvaluationCorpusSnapshot 中每个潜在 `EvidenceUnit × evaluation obligation × validation role` 确定性物化 `ValidationEvidenceEligibilityUnit`，再写唯一 `ValidationEvidenceEligibilityDecision(include_support|include_counterevidence|exclude|failed)`，排除必须引用预注册原因与输入。`eligibility units = terminal decisions`，且 include-support/include-counterevidence/exclude 三个集合必须分别与 EvaluationResult、evidence package projection 和审计排除清单完全相等；漏掉一份协议合格反证、漏 decision 或自由选择性数组均阻断能力声明。

被纳入的验证证据还必须按协议冻结的 producer/operator 生成规则，针对每个证据生产者、调查者或测量操作者物化 `ValidationEvidenceProducerExposureUnit` 与唯一 `ValidationEvidenceProducerExposureDecision(unexposed|possibly_exposed|exposed|unknown)`，并核对候选 Publication/AttentionDelivery 与已知外部传播 lineage。若任何必要 producer/operator 为 exposed、possibly_exposed、unknown 或缺失，该 EvidenceUnit 只能标 `system_induced_validation`/intervention echo，不得标 independent validation；只有全部必要 producer/operator 可证明 unexposed 才进入纯发现能力指标。已有注册来源在收到系统提醒后自行调查也属于暴露，不因未经过 RecruitmentCohort 或产生新 SourceLineage 而洗白。

对通过上述完整性与暴露门禁的验证证据，仍须按预注册规则检查其相对 detection evidence 的独立性：同一材料、同一传播谱系、同一行动者重复自述或同一测量过程重复切片只能标为持续主张，不能标为独立复现。行动者/所有权比较分别使用检测时点和 `outcome_as_of` 快照中可见、对证据时间适用的账号/集团 Version；晚执行不得读取当前画像。独立性无法确认时使用 `DATA_INSUFFICIENT`，不得由模型猜测。

协议、候选冻结记录和每次 `evaluation_ledger_entry` 都必须保存 `previous_entry_hash` 与 `entry_hash` 形成追加式 hash chain，并把周期性 checkpoint 写入与实现服务分离的 WORM 存储或可信时间戳服务。评估协议须在 cohort 开始前锚定；每个候选 commitment 保存 `anchored_at`、`anchor_deadline_at = candidate_frozen_at + 5 分钟`、`reveal_at` 与 inclusion proof，并满足 `anchored_at <= anchor_deadline_at < 最早 outcome_as_of <= reveal_at`。每个 checkpoint 还必须保存外部 `anchor_service_ref`、锚定 Merkle root/受控 commitment、带供应商记录引用与验签材料的内嵌 `checkpoint_anchor_receipt`，以及每条纳入 entry 的可验 `anchor_inclusion_proof`；这些 `*_ref` 是外部系统签发的不可枚举 opaque reference，不声明为本系统 canonical ID 或外键，本地请求时间也不能冒充 `anchored_at`。

只有 `anchored_at <= anchor_deadline_at`、外部 receipt 有效、inclusion proof 能把 entry hash 连到锚定 root，且从协议起点到当前 entry 的每一段前序链都及时锚定，当前能力结论才有效。整条链在结果已知后才一次性锚定，或任一前序 checkpoint 超期、缺失或验签失败，会使依赖它的整条后续链无效；后来锚定更长 Merkle root 不能追认超期历史。普通本地 hash 只能证明内容一致，不能证明揭盲前已存在；上述任一失败使用 `LEDGER_ANCHOR_INVALID`，相关能力评价无效。

协议揭盲前必须冻结 eligible corpus、权限、`source_registry_snapshot_id`、`rights_snapshot_ids[]`、`scope_snapshot_id`、`coverage_policy_version`、`coverage_stratum_version_ids[]`、`configured_data_cutoff`、`required_processing_frontier`、最终 `data_cutoff`、`comparison_watermark`、`selection_completeness_frontier`、卡片/注意力预算、样本量、效应量、置信区间、删失规则、失败定义、锚定 deadline、EvaluationArmManifest，以及 validation evidence 资格、生产者暴露和 detection/validation 独立性规则。热门榜、分层随机、传统编辑、稳定版与挑战版等基线必须使用相同输入截止、权限、来源宇宙和输出预算，并闭合各自全部 arm outputs/obligations/results，否则不得比较发现能力。

凡 outcome 含主观判断，EvaluationProtocolVersion 必须在 cohort 前引用并锚定 `annotation_protocol_version`。AnnotationProtocolVersion 冻结 label、盲法、双标比例、语言/领域 ReviewerQualificationVersion、冲突回避、一致性阈值、弃权和第三方裁决规则；评审者不得看到 system/baseline arm、原始分数、期望方向或另一位初标。每份初标写入不可变 EvaluationJudgment，分歧只追加 AdjudicationDecision，不能覆盖初标。缺资格、盲法破坏、应双标却缺一份、揭盲后改标、分歧未裁决或一致性未达阈值时，相关结果只能使用 `DATA_INSUFFICIENT` 并阻断能力声明，即使 ledger hash 与时间锚有效也不能计成功。

```json
{
  "evaluation_entry_id": "eval_entry_...",
  "evaluation_arm_manifest_id": "eval_arm_manifest_v1",
  "evaluation_arm_id": "arm_system_v1",
  "evaluation_arm_output_snapshot_id": "arm_output_system_30d_...",
  "candidate_id": "cand_...",
  "proposition_family_id": "pf_...",
  "horizon_days": 30,
  "outcome_as_of": "2026-09-01T13:26:00Z",
  "evaluation_corpus_snapshot_id": "eval_corpus_30d_...",
  "snapshot_frozen_at": "2026-09-01T13:27:00Z",
  "evaluation_corpus_snapshot_manifest_hash": "sha256:...",
  "evaluation_corpus_member_counts": {"raw_item_versions": 812, "derived_versions": 426, "evidence_units": 93},
  "snapshot_content_receipt": {
    "provider_record_ref": "opaque:snapshot-receipt/...",
    "content_digest": "sha256:..."
  },
  "snapshot_input_inclusion_proof_refs": ["proof_set_eval_corpus_30d_..."],
  "snapshot_anchor_deadline_at": "2026-09-01T13:31:00Z",
  "snapshot_anchored_at": "2026-09-01T13:29:10Z",
  "evaluation_executed_at": "2026-09-03T04:00:00Z",
  "detection_evidence_unit_ids": ["ev_1"],
  "detection_source_registry_snapshot_id": "srcsnap_20260802_1326",
  "validation_evidence_eligibility_decision_ids": ["ved_support_27", "ved_counter_41", "ved_exclude_72"],
  "validation_support_evidence_unit_ids": ["ev_27"],
  "validation_counterevidence_unit_ids": ["ev_41"],
  "validation_exclusion_decision_ids": ["ved_exclude_72"],
  "validation_evidence_producer_exposure_decision_ids": ["veped_27_researcher_a"],
  "validation_producer_exposure_summary": "unexposed",
  "validation_source_registry_snapshot_id": "srcsnap_20260901_1326",
  "validation_independence_status": "independent",
  "outcome_summary": "出现独立数据生成过程的复现",
  "evaluation_reason_codes": [],
  "evaluation_protocol_version": "eval_v1",
  "previous_entry_hash": "sha256:...",
  "entry_hash": "sha256:...",
  "candidate_commitment_anchor_deadline_at": "2026-08-02T13:31:00Z",
  "candidate_commitment_anchored_at": "2026-08-02T13:29:00Z",
  "candidate_commitment_reveal_at": "2026-08-09T13:26:00Z",
  "candidate_commitment_inclusion_proof": ["sha256:candidate_sibling_1"],
  "checkpoint_anchor_receipt": {
    "provider_record_ref": "opaque:worm-receipt/...",
    "signature": "base64:..."
  },
  "anchor_service_ref": "external:independent-tsa",
  "anchor_deadline_at": "2026-09-03T04:05:00Z",
  "anchored_at": "2026-09-03T04:04:10Z",
  "anchor_inclusion_proof": ["sha256:sibling_1", "sha256:sibling_2"],
  "anchor_chain_status": "valid",
  "time_anchor_verified": true,
  "reason_registry_version": "canonical_reason_registry_v1"
}
```

开发集、阈值调优集和最终评估时间段必须分开。历史案例被用于规则设计后，不得继续作为无偏测试集。对于无法完整观察的“漏报”，应通过固定随机语料审计和预先登记的案例集估计，而不是只复盘后来著名的成功事件。

## 14. 评估指标

系统优化优先级为：覆盖广度与新颖度优先，其次是可追溯性、发现提前量和误报管理。不得以单一“命中率”作为总目标。

### 14.1 广度指标

- 必需覆盖格完成率：冻结 `CoveragePolicyManifest.required_cells` 中达到最低样本要求的单维与高风险交叉格比例；不得用完整五维笛卡尔积作分母；
- 非必需交叉格触达：注册表之外实际观察到的交叉组合，仅作探索统计，不作为硬 SLA；
- 展示覆盖率：日报中实际出现的覆盖分层比例；
- 来源集中度：文档、证据起点、所有权集团三个层级的 HHI 与有效来源数；
- 跨圈层率：进入至少两个社会角色或来源类型的信号比例；
- 长尾曝光率：来自低曝光分层的卡片比例；
- 盲区探索兑现率：保留的探索名额是否实际展示，而不是被热点挤占。

### 14.2 新颖度指标

- 新主题率：与过去 90/365 天主题簇有显著距离的展示比例；
- 新关系率：历史知识图谱中未见实体关系的比例；
- 首现复现率：首次出现后在后续独立窗口或来源复现的比例；
- 陌生领域覆盖：此前 30 天未进入日报的领域数；
- 个人新颖反馈：用户标记“我之前不知道”的比例，只能留在个人产品质量域；不得进入全球模型/规则训练、离线比较、版本晋升、覆盖政策或排序。若需要研究总体可理解性，必须使用另行授权且与生产全球配置完全断开的研究流程，结果不能自动晋升生产版本。

### 14.3 发现与演化指标

- 首次发现提前量：相对预先定义的主流阈值或现实行动节点提前多少时间；
- 扩散路径捕获率：是否记录从最初圈层到后续圈层的实际路径；
- 状态及时性：增强、衰退、证伪后多少时间完成状态更新；
- 再激活识别率：旧主题出现新周期时是否正确链接而非简单重复；
- 历史案例召回：在无未来泄漏回测中的检出比例，按案例类型分组报告。

### 14.4 误报与负担指标

- 候选到 `watch` 的转化率；
- `watch` 后消退、证伪、建立的比例及所需时间；
- 单源候选平均存活时间；
- 每期卡片量、重复卡片率和用户实际阅读负担；
- 高操纵风险候选的识别准确率；
- 误报原因分布：采集问题、转载、季节性、语义误聚类、真实但短暂等。

接受高误报不等于忽略误报。目标是尽早识别误报原因、降低重复打扰，并保留其学习价值，而不是通过压低候选量获得漂亮的精确率。

### 14.5 质量与可审计指标

- 原始证据可追溯率；
- 展示事实的证据链接完整率；
- 独立来源聚类准确率；
- 发布时间与首次可用时间准确率；
- 相同快照与配置的结果可复现率；
- 置信等级校准：各等级后续获得独立支持、消退或证伪的比例；
- 覆盖故障误报率；
- 用户隔离不变性测试通过率。

指标必须按语言、地区、领域、来源类型和检测器拆分，避免总体平均值掩盖局部失败。

## 15. 日报与实时卡片字段

### 15.1 展示顺序

每张卡片默认按以下顺序展示：

1. 中性标题与一句话变化命题；
2. “为什么现在出现”：相对哪个基线发生了什么；
3. 信号类型、生命周期、`signal_first_detected_at`，以及触发原始版本的 `information_arrival_at`；
4. 多维特征，不显示总分；
5. 支持证据与来源独立性；
6. 反证、替代解释、数据缺口与操纵风险；
7. 与上一期相比发生了什么变化；
8. 什么会增强、削弱或证伪该信号；
9. 原文入口和关键段落；
10. AI 推断与事实的明确分界。

卡片首屏必须使用四段式表达，避免用户把异常直接理解成预测：

- **观察到**：原始数据相对基线发生的变化；
- **可能意味着**：当前最简解释，明确标为 AI 推断；
- **尚不能说明**：最容易被误读的未来结论；
- **接下来验证**：可增强、削弱或证伪的具体事实。

用户必须可以从当前值展开查看同分层历史基线图、分母变化和覆盖健康状态。只显示“增长 300%”而不显示从多少增到多少、相对于什么分母和何种基线，不合格。

选择成功必须由 AttentionBudgetManifest 与 AttentionPlacement 证明位置可达，并按冻结 surface/channel/viewport/audience cohort 物化 AttentionDeliveryOpportunity，与具体 placement/PresentationDelivery 双向关联。AttentionDeliveryFrameManifest 还必须在 placement/内容 arm 可见前冻结 audience eligibility、`audience_unit_type=account|device|token|household|person|organization`、`identity_namespace`、linkage/dedup 方法版本、误合并/漏合并验证集与区间、invalid-traffic/prefetch/replay 识别和每窗口 cap；规范 opportunity key 至少包含 `eligible_audience_unit × audience_unit_type × identity_namespace × content/surface × bounded_window × channel`。同一 bot、预取器、push token 或重放请求不得制造多个同单位 unique reach；跨账号/设备/namespace 无法可靠链接者单列 `identity_unknown` 并进入部分识别区间，不得并入 person-level 点值。

系统分别报告 raw deliveries、带 `audience_unit_type/identity_namespace/linkage_method_version` 标签的 unique eligible delivery opportunities 与 reading。一个自然人的 100 个真实账号只能称 100 accounts，一个由 100 人共享的机构 token 只能称 1 token；没有 person-level 身份 oracle、误差界和 claim 复合绑定时，禁止使用未限定的 `unique people/audience reach`。placement 可达但 delivery=0 时 delivered exposure=0，不采集阅读行为时禁止声称实际阅读/认知曝光。日报/雷达从 committed snapshot/render plan 按 query/audience/serializer 确定性生成 PresentationRepresentation expected bytes，PresentationDelivery 的 hash/length 必须完全相等并绑定完整 RevocationDependencySnapshot；调用方自报 `A+B` 的新 hash 不合格。未建模 CDN、304/stale-if-error、Range/resume、stream/SSE 和异步 export 默认拒绝。

报告页眉必须同时显示名义窗口、`configured_data_cutoff` 与作为 effective cutoff 的最终 `data_cutoff`；当 selection completeness frontier 是最小项时，明确说明“选择完整至何时”，不能只展示更乐观的抓取/比较水位。

每个 `surface_section` 都必须渲染栏目状态，但允许 `candidate_count=0`。空栏目必须激活 manifest 的 `section_empty_state:<surface_section>` required ClaimGenerationUnit，并以 ReportClaim/ClaimExpressionVariant/PresentationContentUnit 渲染人类可读 `empty_reason_text`；claim 同时绑定只引用第 17.1 节注册表的 `empty_reason_codes[]`、相关覆盖债务、处理/选择完整前沿、观测四态、rights 状态和下一次检查时间。真实零候选、采集缺口、worker 未运行和撤权重算不得共享一句静态模板；后两类若门禁禁止发布则返回 failed/unavailable。不得为了“每栏都有内容”降低证据门槛、复制其他栏目卡片，或用 controlled-template/static-ui 动态选择一个世界空态主张。

`signal_first_detected_at` 只描述信号生命周期审计时间，不参与原始资讯的报告窗口或新鲜度判断；后两者始终以触发版本的 `information_arrival_at` 为准。

报告级 `surface_section_state` 是 ReportEdition 内的不可变嵌入值，以 `(report_edition_id, surface_section)` 为复合键，不是新的 canonical identity，也不拥有独立双时间；即使无卡片也必须保存和渲染：

```json
{
  "report_edition_id": "report_...",
  "surface_section": "weak_signals",
  "candidate_count": 0,
  "empty_state_claim_generation_unit_id": "claimunit_section_weak_empty_1",
  "empty_state_claim_generation_decision_id": "claimdecision_section_weak_empty_1",
  "empty_state_report_claim_id": "rcl_section_weak_empty_1",
  "empty_state_claim_expression_variant_id": "claimexpr_section_weak_empty_zh_visual_1",
  "empty_state_presentation_content_unit_id": "contentunit_section_weak_empty_1",
  "empty_state_rendered_text_hash": "sha256:...",
  "empty_reason_text": "基线仍在暖机，本期没有可正式展示的候选",
  "empty_reason_codes": ["BASELINE_WARMING_UP"],
  "reason_registry_version": "canonical_reason_registry_v1",
  "coverage_debt_ids": ["debt_language_x"],
  "data_health": "degraded",
  "processing_watermark_ids": ["wm_extract_language_x"],
  "next_check_at": "2026-08-03T11:00:00Z"
}
```

### 15.2 `ReportEdition` 数据契约

```json
{
  "report_edition_id": "report_...",
  "report_schedule_manifest_id": "report_schedule_manifest_v1",
  "report_schedule_slot_id": "slot_20260803_0800",
  "report_pipeline_manifest_id": "report_pipeline_manifest_v1",
  "publication_attempt_id": "pub_attempt_2",
  "nominal_window_start": "2026-08-02T11:00:00Z",
  "nominal_window_end": "2026-08-03T00:00:00Z",
  "scheduled_publish_at": "2026-08-03T00:00:00Z",
  "publication_committed_at": "2026-08-03T00:00:30Z",
  "publication_event_id": "pub_...",
  "configured_data_cutoff": "2026-08-02T23:45:00Z",
  "processing_watermark_ids": ["wm_eligibility_es", "wm_candidate_energy", "wm_select_weak", "wm_claim_global"],
  "required_pipeline_keys": ["eligibility_normalization|signal|stratumv_language_es", "candidate_generation|signal|stratumv_domain_energy", "selection|weak_signals|stratumv_global", "claim_generation|display|stratumv_global"],
  "required_processing_frontier": "2026-08-02T23:45:00Z",
  "comparison_watermark": "2026-08-02T23:45:00Z",
  "selection_completeness_frontier": "2026-08-02T23:43:00Z",
  "data_cutoff": "2026-08-02T23:43:00Z",
  "generation_unit_ids": ["genunit_cov_1_d05", "genunit_cov_2_d07"],
  "candidate_generation_decision_ids": ["cgd_cov_1_d05", "cgd_cov_2_d07"],
  "selection_unit_ids": ["selunit_slot_0800_cand_weak", "selunit_slot_0800_cand_diffusion"],
  "selection_decision_ids": ["sel_weak_1", "sel_diffusion_1"],
  "claim_generation_unit_ids": ["claimunit_overview_observed_1", "claimunit_card_weak_why_now_1"],
  "claim_generation_decision_ids": ["claimdecision_overview_observed_1", "claimdecision_card_weak_why_now_1"],
  "ordered_candidate_ids": ["cand_..."],
  "ordered_report_item_placement_ids": ["placement_report_itemv_3"],
  "ordered_report_card_placement_ids": ["cardplacement_cand_weak_1"],
  "ordered_report_claim_ids": ["rcl_1", "rcl_2"],
  "ordered_claim_expression_variant_ids": ["claimexpr_rcl_1_zh_visual", "claimexpr_rcl_2_zh_visual"],
  "ordered_claim_citation_ids": ["citation_rcl_1_source_1"],
  "ordered_raw_source_listing_reference_ids": ["rawlisting_placement_report_itemv_3_title"],
  "presentation_render_plan_id": "renderplan_report_20260803_0800_zh",
  "ordered_presentation_content_unit_ids": ["contentunit_overview_1", "contentunit_card_weak_1"],
  "initial_composed_presentation_snapshot_id": "composed_report_20260803_0800_initial",
  "publication_lag_minutes": 0.5,
  "cutoff_lag_minutes": 17,
  "single_edition_actuals": {
    "collection_completion": 0.97,
    "parse_completion": 0.95,
    "provenance_completion": 1.0,
    "selection_completion": 1.0
  },
  "edition_status": "degraded",
  "edition_reason_codes": ["DEGRADED_COVERAGE"],
  "reason_registry_version": "canonical_reason_registry_v1",
  "slo_config_version": "provisional_slo_v1",
  "service_slo_snapshot_id": "service_slo_snapshot_20260803_0800",
  "source_registry_snapshot_id": "srcsnap_20260803_0000",
  "rights_snapshot_id": "rights_...",
  "revocation_epoch": 42,
  "clock_health_snapshot_id": "clock_health_20260803_0000",
  "time_quality": "trusted",
  "content_projection_status": "available",
  "system_available_at": "2026-08-03T00:00:30Z",
  "as_of": "2026-08-03T00:00:00Z",
  "run_mode": "prospective"
}
```

`publication_event_id` 的写入是唯一初始发布事实。预览、渲染完成或失败 attempt 不改变 `publication_committed_at`，也不创建 edition；发布事务必须同时验证最新 `revocation_epoch`，并原子写入完整 ReportItemPlacement、ReportCardPlacement、ClaimGenerationUnit/Decision、ReportClaim、ClaimExpressionVariant、ClaimCitation、PresentationRenderPlan/PresentationContentUnit 与 initial ComposedPresentationSnapshot。原始资讯首发/补录、候选卡片位置、逐句主张和最终呈现各自分离；它们分别与 selected units、required claim slots、typed containers、locale/channel variants、citations 和最终 DOM/序列化单元完全对账。ReportEdition 属于普通 immutable record，只使用登记的 `system_available_at/as_of/run_mode`，不拥有 `system_from/valid_from` 或 projected closure。`edition_status` 与 `service_slo_snapshot.service_slo_status` 不得互相推导或覆盖。

每个 REPORT_AMENDMENT 除审计 delta 外，必须在同一 expected-head CAS 事务物化新的完整 `ComposedPresentationSnapshot`，列出当前全部 placements/claims/expression variants/citations/content units、render-plan hash、rights epoch 和 previous snapshot。当前读取只使用 initial PUBLICATION 或最新 amendment head 所引用的一份完整 composed snapshot，不能在请求时并行拼 base 与多条 delta。`ReportViewToken(report_edition_id,presentation_head_event_id,head_revision,composed_snapshot_id,revocation_epoch,render_plan_hash,...)` 绑定分页、详情、缓存和导出；token 成员或 epoch 失配时整体重取/暂不可用，不能同时出现已删除 A、旧 B 与新 B。

### 15.3 卡片数据契约

下例是只读 render projection，不是一个可写的总表。`candidate_*` 来自冻结 SignalCandidate，`lifecycle_state` 与命题解释来自查询 as-of 可见的 SignalVersion/SignalStateEvent，选择字段来自 SelectionDecision，卡片位置来自 ReportCardPlacement；相关原始资料首发/补录另由 ReportItemPlacement 提供。报告截止来自 ReportEdition。示例中的 `title/text` 只是在 PresentationContentUnit 验证后按 ReportClaim/source-text reference 解析出的只读值，必须同时携带 content-unit/ref/hash；它们不是可独立写入的自由文本字段。投影不得把报告时的新证据、状态或 `rendered_as_of` 回写候选 commitment；各源记录继续使用 05 登记的各自 time profile。

```json
{
  "signal_id": "sig_...",
  "signal_version_id": "sigv_4",
  "candidate_id": "cand_...",
  "candidate_frozen_at": "2026-08-02T13:26:00Z",
  "proposition_family_id": "pf_...",
  "proposition_family_rule_version_id": "pfrv_3",
  "emission_policy_version": "emission_policy_v2",
  "baseline_epoch_id": "baseline_epoch_4",
  "nonoverlapping_detection_window": "2026-08-02T11:00:00Z/2026-08-03T00:00:00Z",
  "candidate_emission_key": "sha256:...",
  "evaluation_protocol_version": "eval_v1",
  "evaluation_protocol_hash": "sha256:...",
  "evaluation_horizon_days": [7, 30, 90, 180, 365, 730],
  "detector_manifest_id": "detector_manifest_m3_v1",
  "detector_version_ids": ["detector_d05_v3", "detector_d07_v2"],
  "generation_unit_ids": ["genunit_cov_1_d05", "genunit_cov_2_d07"],
  "candidate_generation_decision_ids": ["cgd_cov_1_d05", "cgd_cov_2_d07"],
  "triggered_detector_keys": ["D05", "D07"],
  "candidate_trigger_event_ids": ["candidate_trigger_event_d07_1"],
  "candidate_trigger_analysis_run_ids": ["run_detect_d05_1", "run_detect_d07_1"],
  "detection_evidence_unit_ids": ["ev_1"],
  "source_context": {
    "source_registry_snapshot_id": "srcsnap_20260803_0000",
    "endpoint_version_ids": ["sepv_9"],
    "publisher_account_version_ids": ["pav_12", "pav_38"],
    "owner_group_version_ids": ["ogv_4"],
    "historical_rights_snapshot_ids": ["rights_20260803_0000"],
    "owner_group_unknown_count": 1
  },
  "coverage_item_ids": ["cov_1", "cov_2"],
  "primary_coverage_item_id": "cov_1",
  "primary_coverage_cell": "language:es|domain:energy",
  "coverage_stratum_version_ids": ["stratumv_language_es", "stratumv_domain_energy"],
  "presentation_render_plan_id": "renderplan_report_20260803_0800_zh",
  "title_content_unit_id": "contentunit_card_weak_title_1",
  "title_report_claim_id": "rcl_title_1",
  "title_claim_expression_variant_id": "claimexpr_rcl_title_1_zh_visual",
  "title_rendered_text_hash": "sha256:...",
  "title": "中性标题",
  "proposition": "可检验的变化命题",
  "signal_types": ["emergence", "diffusion"],
  "allocation_lane": "long_tail_novelty",
  "surface_sections": ["weak_signals", "cross_group_diffusion"],
  "selection_decisions": [
    {
      "selection_decision_id": "sel_weak_1",
      "surface_section": "weak_signals",
      "ranking_rule_id": "weak_signals_rank_v1"
    },
    {
      "selection_decision_id": "sel_diffusion_1",
      "surface_section": "cross_group_diffusion",
      "ranking_rule_id": "diffusion_rank_v1"
    }
  ],
  "rendered_selection_decision_id": "sel_weak_1",
  "lifecycle_state": "watch",
  "signal_first_detected_at": "2026-08-02T13:20:00Z",
  "rendered_as_of": "2026-08-03T00:00:00Z",
  "discovery_delay_seconds": 1800,
  "report_card_placement_id": "cardplacement_cand_weak_1",
  "presentation_event_id": "pub_...",
  "selection_unit_id": "selunit_slot_0800_cand_weak",
  "selection_decision_id": "sel_weak_1",
  "surface_section": "weak_signals",
  "card_order": 1,
  "related_information_arrival_ids": ["arrival_itemv_3"],
  "related_report_item_placement_ids": ["placement_report_itemv_3"],
  "correction": {
    "is_correction": false,
    "revision_assessment_version_id": null,
    "decision_system_available_at": null,
    "supersession_event_id": null,
    "report_amendment_id": null,
    "reason_codes": []
  },
  "observation_window": {
    "start": "2026-08-02T11:00:00Z",
    "end": "2026-08-03T00:00:00Z"
  },
  "why_now": [
    {"presentation_content_unit_id": "contentunit_card_weak_why_now_1", "report_claim_id": "rcl_1", "claim_expression_variant_id": "claimexpr_rcl_1_zh_visual", "rendered_text_hash": "sha256:...", "text": "相对 28 天同星期基线出现异常增长", "observation_ids": ["obs_1"]}
  ],
  "interpretation": {
    "presentation_content_unit_id": "contentunit_card_weak_interpretation_1",
    "report_claim_id": "rcl_2",
    "claim_expression_variant_id": "claimexpr_rcl_2_zh_visual",
    "rendered_text_hash": "sha256:...",
    "text": "这可能代表……；此句为 AI 推断",
    "assertion_type": "ai_inference",
    "entailment_result": "not_applicable",
    "inference_input_scope_ids": ["scope_measurement_1", "scope_measurement_2"],
    "inference_analysis_run_id": "run_inference_1",
    "inference_support_status": "supported",
    "counterevidence_analysis_run_ids": ["run_counterevidence_1"],
    "observation_ids": ["obs_1", "obs_2"]
  },
  "not_claimed": {
    "presentation_content_unit_id": "contentunit_card_weak_not_claimed_1",
    "report_claim_id": "rcl_3",
    "claim_expression_variant_id": "claimexpr_rcl_3_zh_visual",
    "rendered_text_hash": "sha256:...",
    "text": "当前证据不能说明该变化会成为主流或产生重大影响"
  },
  "baseline_comparison": {
    "metric": "topic_share_per_comparable_document",
    "current_numerator": 41,
    "current_denominator": 8200,
    "current_value": 0.005,
    "baseline_median": 0.0012,
    "baseline_window": "28d_same_weekday",
    "change": 0.0038,
    "percentile": 96,
    "interval": [0.0039, 0.0062],
    "q_value": 0.08,
    "data_health": "medium"
  },
  "scope": {
    "regions": ["..."],
    "languages": ["..."],
    "domains": ["..."],
    "source_types": ["..."]
  },
  "signal_vector": {
    "attention": {"percentile": 96, "raw": 41},
    "novelty": {"percentile": 91},
    "diffusion": {"percentile": 63, "actor_group_count": 2, "source_registry_snapshot_id": "srcsnap_20260803_0000"},
    "persistence": {"active_windows": 2},
    "action": {"max_stage": 1},
    "independence": {"raw_items": 18, "source_lineages": 3, "evidence_units": 3, "publisher_accounts": 2, "owner_groups": 1, "owner_group_unknown": 1, "source_registry_snapshot_id": "srcsnap_20260803_0000"},
    "counterevidence_level": "medium",
    "manipulation_risk": "low",
    "data_quality": "medium"
  },
  "confidence": {
    "observation": "C2",
    "interpretation": "C1",
    "reasons": ["..."],
    "uncertainties": ["..."]
  },
  "detector_warmup": {
    "D05": "available",
    "D07": "warming_up"
  },
  "claim_generation_unit_ids": ["claimunit_card_weak_title_1", "claimunit_card_weak_why_now_1", "claimunit_card_weak_interpretation_1", "claimunit_card_weak_not_claimed_1"],
  "claim_generation_decision_ids": ["claimdecision_card_weak_title_1", "claimdecision_card_weak_why_now_1", "claimdecision_card_weak_interpretation_1", "claimdecision_card_weak_not_claimed_1"],
  "report_claim_ids": ["rcl_title_1", "rcl_1", "rcl_2", "rcl_3"],
  "claim_expression_variant_ids": ["claimexpr_rcl_title_1_zh_visual", "claimexpr_rcl_1_zh_visual", "claimexpr_rcl_2_zh_visual", "claimexpr_rcl_3_zh_visual"],
  "claim_citation_ids": ["citation_rcl_1_ev_1"],
  "presentation_content_unit_ids": ["contentunit_card_weak_title_1", "contentunit_card_weak_why_now_1", "contentunit_card_weak_interpretation_1", "contentunit_card_weak_not_claimed_1"],
  "evidence": [
    {
      "claim_citation_id": "citation_rcl_1_ev_1",
      "report_claim_id": "rcl_1",
      "citation_role": "entails",
      "evidence_unit_id": "ev_1",
      "evidence_relation": "supports",
      "evidence_role": "primary_record",
      "assertion_type": "speech_act",
      "evidence_scope_ids": ["scope_statement_1"],
      "entailment_result": "entailed",
      "entailment_check": {
        "subject_match": true,
        "negation_match": true,
        "scope_match": true
      },
      "entailment_analysis_run_id": "run_entailment_1"
    }
  ],
  "counterevidence": [
    {"evidence_unit_id": "ev_9", "evidence_relation": "contradicts", "summary": "..."}
  ],
  "alternative_explanations": ["..."],
  "change_since_last_report": ["新增一个独立地区的证据"],
  "would_strengthen": ["..."],
  "would_weaken": ["..."],
  "would_falsify": ["..."],
  "watch_metrics": ["..."],
  "next_check_at": "2026-08-04T00:00:00Z",
  "provenance_refs": [
    {
      "item_id": "item_1",
      "item_version_id": "itemv_3",
      "endpoint_version_id": "sepv_9",
      "publisher_account_id": "pa_12",
      "publisher_account_version_id": "pav_12",
      "owner_group_id": "og_4",
      "owner_group_version_id": "ogv_4",
      "source_registry_snapshot_id": "srcsnap_20260803_0000",
      "rights_snapshot_id": "rights_20260803_0000",
      "title": "原文标题",
      "publisher": "来源",
      "source_published_at": "...",
      "event_time": "...",
      "item_first_seen_at": "...",
      "version_observed_at": "...",
      "captured_at": "...",
      "version_available_at": "...",
      "information_arrival_at": "...",
      "revision_assessment": {
        "revision_assessment_version_id": "rav_7",
        "revision_type": "substantive_addition",
        "reportability": "reportable",
        "decision_system_available_at": "2026-08-02T22:32:08Z"
      },
      "clock_source_id": "clock_registry_1",
      "clock_skew_bound_ms": 50,
      "clock_health_snapshot_id": "clock_health_20260802_2232",
      "time_quality": "trusted",
      "ingest_sequence": 182991,
      "ingest_domain_id": "ingest_raw_item_registry",
      "causal_parent_event_ids": ["collection_opportunity_state_event_182990"],
      "queue_offset": "partition-3:88012",
      "url": "...",
      "span_ref": "paragraph:12",
      "language": "...",
      "access_level": "metadata_and_excerpt",
      "content_projection_status": "available",
      "purpose_authorization_id": "auth_display_1",
      "rights_grant_version_id": "rights_grant_display_v2",
      "authorized_content_scope_id": "scope_display_200_chars",
      "resource_version_hash": "sha256:...",
      "target_processor": "report_renderer",
      "checked_at": "2026-08-02T23:59:55Z",
      "expires_at": "2026-08-03T00:04:55Z",
      "revocation_epoch": 42
    }
  ],
  "provenance": {
    "report_schedule_manifest_id": "report_schedule_manifest_v1",
    "report_schedule_slot_id": "slot_20260803_0800",
    "report_pipeline_manifest_id": "report_pipeline_manifest_v1",
    "publication_attempt_id": "pub_attempt_2",
    "scheduled_publish_at": "2026-08-03T00:00:00Z",
    "preview_generated_at": "...",
    "publication_committed_at": "2026-08-03T00:00:30Z",
    "publication_event_id": "pub_...",
    "configured_data_cutoff": "2026-08-02T23:45:00Z",
    "processing_watermarks": {
      "eligibility_normalization|signal|stratumv_language_es": {
        "processing_watermark_id": "wm_eligibility_es",
        "pipeline_stage": "eligibility_normalization",
        "purpose": "signal",
        "stratum_id": "language:es",
        "stratum_version_id": "stratumv_language_es",
        "frontier_at": "2026-08-02T23:50:00Z",
        "watermark_computed_at": "2026-08-02T23:57:00Z",
        "scope_snapshot_id": "scope_17",
        "cursor_checkpoint_ids": ["cursor_checkpoint_es_184"],
        "watermark_gap_ids": [],
        "excluded_reason_codes": [],
        "completeness": "complete"
      },
      "candidate_generation|signal|stratumv_domain_energy": {
        "processing_watermark_id": "wm_candidate_energy",
        "pipeline_stage": "candidate_generation",
        "purpose": "signal",
        "stratum_id": "domain:energy",
        "stratum_version_id": "stratumv_domain_energy",
        "frontier_at": "2026-08-02T23:45:00Z",
        "watermark_computed_at": "2026-08-02T23:58:00Z",
        "scope_snapshot_id": "scope_17",
        "cursor_checkpoint_ids": [],
        "watermark_gap_ids": [],
        "excluded_reason_codes": [],
        "completeness": "complete"
      },
      "selection|weak_signals|stratumv_global": {
        "processing_watermark_id": "wm_select_weak",
        "pipeline_stage": "selection",
        "purpose": "weak_signals",
        "stratum_id": "global",
        "stratum_version_id": "stratumv_global",
        "frontier_at": "2026-08-02T23:43:00Z",
        "watermark_computed_at": "2026-08-02T23:59:00Z",
        "scope_snapshot_id": "scope_17",
        "cursor_checkpoint_ids": [],
        "watermark_gap_ids": [],
        "excluded_reason_codes": [],
        "completeness": "complete"
      },
      "selection|cross_group_diffusion|stratumv_global": {
        "processing_watermark_id": "wm_select_diffusion",
        "pipeline_stage": "selection",
        "purpose": "cross_group_diffusion",
        "stratum_id": "global",
        "stratum_version_id": "stratumv_global",
        "frontier_at": "2026-08-02T23:44:00Z",
        "watermark_computed_at": "2026-08-02T23:59:05Z",
        "scope_snapshot_id": "scope_17",
        "cursor_checkpoint_ids": [],
        "watermark_gap_ids": [],
        "excluded_reason_codes": [],
        "completeness": "complete"
      },
      "claim_generation|display|stratumv_global": {
        "processing_watermark_id": "wm_claim_global",
        "pipeline_stage": "claim_generation",
        "purpose": "display",
        "stratum_id": "global",
        "stratum_version_id": "stratumv_global",
        "frontier_at": "2026-08-02T23:43:00Z",
        "watermark_computed_at": "2026-08-02T23:59:10Z",
        "scope_snapshot_id": "scope_17",
        "cursor_checkpoint_ids": [],
        "watermark_gap_ids": [],
        "excluded_reason_codes": [],
        "completeness": "complete"
      }
    },
    "required_pipeline_keys": ["eligibility_normalization|signal|stratumv_language_es", "candidate_generation|signal|stratumv_domain_energy", "selection|weak_signals|stratumv_global", "claim_generation|display|stratumv_global"],
    "required_processing_frontier": "2026-08-02T23:45:00Z",
    "comparison_watermark": "2026-08-02T23:45:00Z",
    "selection_completeness_frontier": "2026-08-02T23:43:00Z",
    "data_cutoff": "2026-08-02T23:43:00Z",
    "generation_unit_ids": ["genunit_cov_1_d05", "genunit_cov_2_d07"],
    "candidate_generation_decision_ids": ["cgd_cov_1_d05", "cgd_cov_2_d07"],
    "selection_unit_ids": ["selunit_slot_0800_cand_weak", "selunit_slot_0800_cand_diffusion"],
    "run_mode": "prospective",
    "detector_manifest_id": "detector_manifest_m3_v1",
    "model_ids": ["model_1"],
    "analysis_run_ids": ["run_detect_d05_1", "run_inference_1"],
    "feature_artifact_ids": ["fa_1"],
    "baseline_epoch_id": "baseline_epoch_4",
    "coverage_policy_version": "coverage_policy_v1",
    "coverage_stratum_version_ids": ["stratumv_language_es", "stratumv_domain_energy"],
    "scope_snapshot_id": "scope_17",
    "source_registry_snapshot_id": "srcsnap_20260803_0000",
    "endpoint_version_ids": ["sepv_9"],
    "publisher_account_version_ids": ["pav_12", "pav_38"],
    "owner_group_version_ids": ["ogv_4"],
    "reason_registry_version": "canonical_reason_registry_v1",
    "rights_snapshot_id": "rights_...",
    "revocation_epoch": 42,
    "time_quality": "trusted"
  },
  "selection_trace": {
    "selection_decision_id": "sel_weak_1",
    "selection_unit_id": "selunit_slot_0800_cand_weak",
    "candidate_id": "cand_...",
    "detector_manifest_id": "detector_manifest_m3_v1",
    "triggered_detector_keys": ["D05", "D07"],
    "signal_types": ["emergence", "diffusion"],
    "allocation_lane": "long_tail_novelty",
    "surface_section": "weak_signals",
    "ranking_rule_id": "weak_signals_rank_v1",
    "quota_bucket": "language:es|domain:energy",
    "pareto_front": true,
    "exploration_pick": false,
    "decision": "selected",
    "selection_reason_codes": ["ALLOCATION_LANE_ASSIGNED"],
    "tie_break": {"field": "candidate_id", "value": "cand_..."},
    "system_available_at": "2026-08-03T00:00:20Z",
    "as_of": "2026-08-03T00:00:00Z",
    "run_mode": "prospective"
  }
}
```

### 15.4 卡片展示约束

- 每张卡片至少提供一个符合来源许可与隐私策略的 `provenance_ref`；允许形式为获准快照、受限内部记录、结构化定位、许可内片段、元数据加原链接或删除墓碑，不要求保存或展示全文；
- 单源候选可以展示，但必须显示“单源、未确认”；
- 每一条 `why_now` 和事实陈述必须绑定观察 ID；
- 反证为空时必须说明搜索范围和覆盖限制；
- 不得用颜色暗示单一好坏或未来涨跌；
- 更新卡片优先展示“新增了什么证据”，而不是重复完整摘要；
- 实时卡片必须显示数据延迟与最后更新时间；
- AI 翻译和关键段落必须允许切回原文。
- 所有内部原因码都必须映射成简明的人类可读解释；用户不应理解算法名才能知道卡片为何出现；
- 若基线、分母或覆盖质量无法解释，产品不得仅凭醒目视觉展示百分比变化。

## 16. 最小实现数据表

v0.1 至少需要下列逻辑表或等价对象：

| 表 | 关键字段 |
|---|---|
| `global_identity_registry` / `object_identity_registry` / `record_identity_registry` / `event_base` / `event_type_definitions` / `event_state_definitions` / `event_state_transition_definitions` / `event_api_aliases` | object/record/event 单一身份、typed composite FK、subtype、aggregate allowlist、完整 state transition/guard children 与 API ID=EventBase.event_id alias；未知 pair/alias fail closed |
| `collection_opportunities` / `captures` / `raw_artifacts` | 计划采集机会与端点、尝试时间、terminal 状态、`cursor_checkpoint_id`、许可内 payload/片段/元数据指针、内容哈希、权限与隔离状态 |
| `content_cursors` / `content_cursor_checkpoints` | 稳定 `cursor_id`、不可变 `cursor_checkpoint_id`、分页/增量值、`previous_cursor_checkpoint_id`、transition reason 与受控 sequence；推进、回退和重建只追加 checkpoint |
| `raw_items` / `raw_item_versions` | 稳定 `item_id`、不可变 `item_version_id`、许可内快照或元数据指针、哈希、来源、语言、`event_time`、`source_published_at`、`source_updated_at`、`item_first_seen_at`、`version_observed_at`、`captured_at`、`version_available_at`、权限与红删状态；不存可修改的 revision/reportability 判断 |
| `canonical_items` / `canonical_item_versions` | 稳定身份与规范文本/结构、语言、去重映射的不可变版本 |
| `publisher_accounts` / `publisher_account_versions` | 稳定发布者/账号身份，以及不可变名称、来源类型、社会角色、地区、平台状态与 `owner_group_version_id`；未知字段显式保存，重分类只追加版本 |
| `owner_groups` / `owner_group_versions` | 稳定控制集团身份，以及不可变成员/控制边、母子集团与 unknown 状态；收购、拆分和控制修订只追加版本 |
| `source_endpoints` / `source_endpoint_versions` / `collection_plan_manifests` | 稳定端点及不可变 URL、协议、法域、描述性 `source_declared_update_cadence`；执行机会唯一由冻结 `planned_poll_cadence` 生成，二者偏离可审计 |
| `source_registry_snapshots` | 某个 `as_of` 内容寻址物化的 `endpoint_version_id`/`publisher_account_version_id`/`owner_group_version_id`/`rights_snapshot_id`/`collection_plan_id` 清单、系统可用时间、成员数与 manifest hash；不得只保存可重跑查询 |
| `source_lineages` / `source_lineage_versions` | 稳定传播起点身份及成员、依赖边和独立性上下界快照 |
| `translation_artifacts` / `translation_artifact_versions` | 稳定翻译任务及具体源版本、目标语言、模型、译文与 `system_available_at`；新翻译不覆盖旧版 |
| `event_clusters` / `event_cluster_versions` | 稳定事件身份及成员、事件时间/范围和状态快照；允许输入没有事件簇 |
| `entities` / `entity_versions` | 作者及其他实体的稳定身份和版本引用；账号、组织所有权、地区与角色不得以当前字段覆盖 `PublisherAccountVersion`/`OwnerGroupVersion`；可靠性记录限定到命题类型与时间范围，不保存全局“可信分” |
| `document_dependencies` | 文档间引用、转载、相似、所有权和协同关系，以及构边所用 `source_registry_snapshot_id`、两端账号/集团 Version 和 unknown 状态 |
| `evidence_units` | 证据起点、成员文档、证据角色、独立性摘要 |
| `rights_grants` / `rights_grant_versions` / `authorized_content_scopes` / `purpose_authorizations` | grant、资源 typed FK、span/bytes、processor、purpose、transform、derivative、retention 与 epoch 的复合约束；EvidenceScope 不承担许可 |
| `observations` / `observation_versions` | 稳定观察身份及可验证陈述、测量、分母、范围、证据链接和断言门禁的不可变版本 |
| `observation_series` / `observation_series_snapshots` | 稳定序列及某个 as-of 的测量、分母、采样政策、健康状态和方法快照 |
| `concept_clusters` / `concept_cluster_versions` | 稳定概念身份及主题/叙事簇快照 |
| `claim_relations` / `claim_relation_versions` | 稳定关系身份及 assertion type、主体、否定、限定、证据范围和关系快照 |
| `actor_actions` / `actor_action_versions` | 稳定行动身份及意向、承诺、执行、取消或结果快照 |
| `revision_assessments` / `revision_assessment_versions` | 稳定评估身份、before/after raw version、`revision_type`、独立 `reportability`、`decision_system_available_at`、输入 diff、规则/模型、理由与 supersession；重分类追加版本，不修改 raw version 或旧 assessment |
| `supersession_events` | 被取代版本、后继版本、事件可用时间、原因码与主体；用于投影闭合区间，旧版本行不回写 |
| `coverage_items` | L2/L3 计数投影；保存规范 projection key、UUIDv5 identity、scope/policy/semantics/kind/typed inputs/strata/role 并对完整 key 唯一；候选可关联多个但须指定主项与主覆盖格 |
| `coverage_policy_manifests` / `coverage_strata` / `coverage_stratum_versions` | `coverage_policy_version` 内的 required cell registry、分配轨道、容量，以及稳定 `stratum_id`/不可变 `stratum_version_id` 的分类边界；水位、分母和历史报告冻结引用版本 |
| `detectors` / `detector_versions` / `detector_manifests` | D01–D11 仅为展示 key；manifest 每个 entry FK 到具体 `detector_id/detector_version_id`，冻结输入、窗口、暖机、候选和确认规则 |
| `source_discovery_program_manifests` / `source_discovery_frame_opportunities` / `source_discovery_frame_decisions` / `source_discovery_frame_manifests` / `source_discovery_opportunities` / `source_discovery_decisions` / `recruitment_cohorts` / `conditioning_ancestry_closures` | program 冻结应运行 frame 的完整分母及 run/skipped/failed terminal，run 一对一引用 frame；frame 再闭合全部来源机会/决定；条件化来源不得跨 ID 洗白 |
| `sequential_testing_universe_manifests` / `hypothesis_test_opportunities` / `hypothesis_test_generation_decisions` / `test_statistic_input_snapshots` / `sequential_hypothesis_family_manifests` / `sequential_hypothesis_ledger_entries` | 全量被评分机会、root alpha、互斥 family 与 ledger；每项输入 snapshot 冻结 filtration、抽样/停止、数据生成 lineage、dependence cluster 和 conditional-validity method；scored=generated=ledger terminals，拆族、漏机会或条件无效均阻断 |
| `proposition_families` / `proposition_family_rule_versions` | 稳定命题族及揭盲前冻结的规范化/归并规则；后续规则不回填 |
| `baseline_epochs` / `candidate_emission_policies` | 覆盖/方法连续 epoch，以及不重叠检测窗、重触发、冷却与 recurrence 规则；共同决定幂等发射 key |
| `candidate_generation_units` / `candidate_generation_decisions` | 先确定性物化 `generation_unit_id = H(scope_snapshot_id, pipeline_key, coverage_item_id, detector_version_id)`，再以 `UNIQUE(generation_unit_id)` 保存唯一 terminal candidate/no-candidate/failed；缺 unit/decision 形成 WatermarkGap |
| `signal_candidates` / `candidate_trigger_events` | candidate 冻结初始 family、检测 universe、emission key、协议、来源/分层与主预算；后续 detector/evidence 只追加 CandidateTriggerEvent，不回写候选或扩大检测集 |
| `signals` | 稳定信号身份；命题、类别和生命周期不写入 identity 行 |
| `signal_versions` | 每次命题、特征、置信、解释的不可变快照 |
| `signal_evidence_links` | 支持、反驳、背景、不确定关系、主张类型、证据范围、蕴含或 inference-support 门禁与权限引用 |
| `signal_state_events` | 状态转换、时间、原因和算法/人工主体 |
| `corpus_scope_snapshots` | 某次处理或比较实际纳入/排除的对象 ID 物化清单；与 `source_registry_snapshot_id`、`coverage_policy_version`、`coverage_stratum_version_ids[]` 共同冻结覆盖和 cadence 分母，不另造动态 coverage snapshot |
| `claim_generation_units` / `claim_generation_decisions` | 按 presentation context×typed container×claim-slot schema 确定性物化；每个 unit 唯一 terminal claim/not_applicable/failed，required slot 不得为空，outcome=claim 与一个 ReportClaim 一一对应 |
| `report_claims` / `claim_expression_variants` | presentation event、日报或雷达 owner、typed ReportEdition/ReportCardPlacement/GlobalRadarSnapshot/RadarCardPlacement container、容器内顺序、canonical proposition，以及每 locale/channel/variant role 的表达、翻译工件、语义等价决定与 hash |
| `claim_citations` / `raw_source_listing_references` | 前者绑定 claim、exact source/EvidenceScope/rights/citation role；后者只绑定 ReportItemPlacement、exact metadata/title/rights/hash且无 claim；两类 XOR，无关邻接来源不能冒充证据 |
| `presentation_render_plans` / `presentation_content_units` | 每 event 唯一 plan；最终标题/正文/caption/tooltip/alt/ARIA/通知/导出的 channel、locale、typed container、order、kind-specific child ref 与 rendered hash；最终 DOM/序列化输出双向一致，禁止裸多态和未登记自由文本 |
| `composed_presentation_snapshots` | initial publication 或每个 amendment head 的完整累计 placements/claims/variants/citations/content units 与 render hash；当前读不拼 base+delta |
| `report_schedule_manifests` / `report_schedule_slots` / `report_slot_state_events` | 窗口前冻结的时区/tzdb/recurrence/例外日/确定性 slot 规则、预物化不可变 slot 与追加状态事件；状态只投影，漏建也按 manifest 计入分母 |
| `report_pipeline_manifests` | 非空 required `stage × purpose × stratum_version_id`、DetectorVersion 集、scope、terminal record 与完整性 oracle；不能从实际运行任务反推 |
| `publication_attempts` / `publication_events` | 每次提交尝试与成功原子发布事实；只有成功 attempt 产生一对一 publication event/edition，漏发无虚构 edition |
| `report_editions` / `report_amendments` | slot/成功 attempt/唯一 initial publication event、pipeline manifest、全部 generation/selection/claim 决定、名义窗口、frontiers、最终 `data_cutoff`、状态、rights/epoch；后续更正走 amendment 且每 head 指向完整 composed snapshot |
| `reportable_arrivals` / `report_item_placements` | typed subject identity、`information_arrival_id`、nominal slot、`presentation_event_id/item_order` 与唯一 first/backfill；每 presentation event 的 arrival/order 唯一，每 arrival 全局最多一条 first |
| `report_card_placements` | 每个 selected CandidateSelectionUnit 的 `presentation_event_id/selection_unit_id/selection_decision_id/candidate_id/surface_section/card_order/signal_version_id`；未选 unit 无卡片；发布/修订事务同时提交并对账两类完整 placement 集合 |
| `radar_surfaces` / `radar_pipeline_manifests` | 稳定实时表面，以及 scope/method epoch、required keys、selection/claim/render schema、刷新目标、head dominance、断序与 continuation membership 规则 |
| `global_radar_snapshots` / `radar_card_placements` / `radar_publication_events` | 完整公共 snapshot、卡片与 RADAR_SURFACE_HEAD expected-head CAS；冻结 frontiers/cutoff/rights epoch/claims/variants/citations/render plan，孤儿 snapshot 不对外可见 |
| `service_slo_snapshots` | `slo_config_version`、滚动窗口/slot 分母、准时率、cutoff-lag P95 与 `service_slo_status`；不覆盖单期状态 |
| `candidate_selection_units` / `selection_decisions` | 先物化绑定 run/slot、candidate、surface/allocation context 的确定性 `selection_unit_id`，再以 `UNIQUE(selection_unit_id)` 保存唯一 terminal 决定、ranking、配额、Pareto、探索与理由 |
| `pre_detection_exploration_eligibility_units` / `eligibility_decisions` / `exploration_units` / `exploration_decisions` / `exploration_material_placements` | 每 CoverageItem 资格终态、eligible 随机探索与 `not_a_signal=true` 展示；不能只为赢家建 unit |
| `attention_budget_manifests` / `attention_placements` / `attention_delivery_frame_manifests` / `attention_delivery_opportunities` / `attention_delivery_decisions` | 位置预算、实际位置和冻结 surface/channel/viewport/audience 的可交付机会；frame 必填 audience_unit_type、identity_namespace、linkage/dedup version 与误差界，无 delivery 不称曝光、无 person-level oracle 不称 unique people |
| `delivery_policy_manifests` / `presentation_representations` / `presentation_deliveries` | committed render 的 query/audience/serializer expected bytes 与实际交付；hash/length 精确相等并绑定完整 revocation dependency set |
| `processing_watermarks` / `watermark_gaps` | 权威键为 `pipeline_stage × purpose × stratum_version_id`；保存 arrival frontier、scope、coverage policy、cursor 与 gap IDs；gap 只由事件闭合，不能删除后越过 |
| `evaluation_corpus_snapshots` | `candidate_id`、horizon、`outcome_as_of`、`snapshot_frozen_at`、按规范对象类型分列的不可变 Version/EvidenceUnit ID 清单、`source_registry_snapshot_id`、`rights_snapshot_ids[]`、`scope_snapshot_id`、`coverage_policy_version`、`coverage_stratum_version_ids[]`、逐项 hash、计数、manifest/内嵌 content receipt、每项 inclusion proof 及 `outcome_as_of+5m` 外部锚；不是查询定义 |
| `evaluation_arm_manifests` / `evaluation_arm_generation_units` / `evaluation_arm_generation_decisions` / `evaluation_arm_output_snapshots` | 每个系统/热门/随机/编辑/champion/challenger arm 的规则版本、相同输入边界、K、随机种子、全量 generation terminal 与揭盲前完整有序输出；arm output members 必须与 obligations/results 集合相等 |
| `evaluation_obligations` / `evaluation_snapshot_decisions` / `evaluation_results` | candidate×protocol×horizon 唯一义务、snapshot/missed XOR 与唯一正式结果；并发冲突不能择优 |
| `validation_evidence_eligibility_units` / `validation_evidence_eligibility_decisions` | 对 EvaluationCorpusSnapshot 中每个 EvidenceUnit×obligation×protocol role 的支持/反证/排除/失败唯一终态；与 Result、evidence package 和排除清单四方集合相等，不能自由挑证据 |
| `validation_evidence_producer_exposure_units` / `validation_evidence_producer_exposure_decisions` | 每项纳入验证证据的生产者/调查者/测量操作者对 candidate publication/delivery 的暴露义务与唯一终态；暴露、不确定或缺失只能标 system-induced validation，不能标独立复现 |
| `outcome_frame_manifests` / `outcome_generation_units` / `outcome_generation_decisions` / `outcome_units` / `outcome_clusters` / `candidate_outcome_links` / `outcome_actor_exposure_units` / `outcome_actor_exposure_decisions` | 独立现实结果机会全分母、共享结果/相关簇与候选链接；每个因果行动者有暴露唯一终态，link 用最坏情形 reducer 聚合；recall/coverage 读取 frame 全集且不能挑未暴露代表人 |
| `capability_claim_family_manifests` / `capability_claim_units` / `capability_claim_decisions` | protocol×metric×horizon×subgroup×look 声明 universe、multiplicity 与唯一 publishability；不得只发幸运 sibling |
| `evaluation_ledger_entries`（含批次 checkpoint 结构） | candidate/family 结果、检测/验证证据、`evaluation_executed_at`、前序/当前 hash、候选 commitment deadline/reveal，以及内嵌 checkpoint 的外部 `anchored_at`、opaque service/receipt refs、Merkle inclusion proof 与整链验签状态；不为 checkpoint 另造无 owner 的根 ID |
| `annotation_protocol_versions` / `reviewer_qualification_versions` / `evaluation_judgments` / `adjudication_decisions` | 主观 outcome 的预注册 label、盲法、双标、资格、一致性与不可覆盖初标/追加裁决 |
| `analysis_runs` / `feature_artifacts` | 不可变派生运行、内容寻址输出及选择前特征工件，包括输入清单、来源注册表/账号/集团/分层 Version 引用，用于重放和漂移比较 |
| `rights_snapshots` 与嵌入式 `provenance_ref` 投影 | provenance_ref 只组合 EvidenceScope、RawItemVersion、PurposeAuthorization 与外链/墓碑，不另造无 owner 的根 ID；访问仍按最新 epoch 复核 |
| `correction_events` / `correction_proposals` / `correction_proposal_decision_events` | 全局公共更正与个人建议严格分域；accept/reject/withdraw 只追加 expected-head 决定，只有 accepted 可引用公共 CorrectionEvent |
| `deletion_events` | 合规红删、级联删除结果、最小非内容审计状态和评估删失关联；内容墓碑是事件投影，不是可作证据的新根对象 |
| `clock_sources` / `clock_health_snapshots` / `clock_policy_manifests` / `ingest_domains` | UTC 时间源、偏移界、quorum/TTL 健康；EventBase 保存 `ingest_domain_id`、域内 sequence，跨域因果以 EventCausalParent 为权威、JSON 数组仅投影 |
| `personal_scopes` / `personal_scope_versions` / `conversation_turns` / `private_query_contexts` / `query_plan_records` / `public_only_input_snapshots` | scope+owner+authz epoch 租户根、个人对话/查询及公共输入零 private-lineage 证明；不得跨租户或写入全球日志 |
| `model_task_manifests` / `outbound_payload_manifests` / `provider_context_snapshots` / `model_invocations` / `provider_callback_receipts` / `model_output_validation_units/decisions/attempts` | 实际字节与 remote effective context、签名一次性 callback、required validator 全集和 tainted typed decisions；不能驱动控制面 |
| `revocation_dependency_snapshots` | invocation、context、callback、cache/export/token/delivery 依赖的完整 `(domain,epoch)` 有序集合；任一 head 改变整体失效 |
| `compliance_revocation_ledger_checkpoints` / `recovery_fences` | 独立单调删除/撤权高水位与生产开放前 replay/redaction/key-destruction/canary 门禁；缺失或回滚时 deny-all |
| `memory_candidates` / `memory_candidate_decision_events` / `user_memories` / `user_memory_versions` | 待确认记忆、接受/拒绝/撤销历史、稳定记忆身份、追加版本、导出与删除生命周期；拒绝不进入解释 |
| `test_definitions` / `test_definition_versions` / `test_catalog_manifests` / `test_runs` / `test_results` / `gate_decisions` / `test_governance_policies` / `test_waivers` | 定义、完整目录、执行结果和 gate 分离；P0 applicability always、语义不可降级、空目录/缺结果 fail closed |

本节只列逻辑存储，不重定义字段原型。每个对象必须逐项解析到 05 的 archetype 与 time-profile registry：所有 record 有受控 system-availability time，只有登记的 bitemporal version 才有 valid/system interval，standalone snapshot 与 manifest 使用自己的冻结/生效时间。个人记忆、反馈和对话不得与候选、信号、训练、离线评估或全局版本晋升建立可用于计算的反向依赖；对话服务只读全局信号并读取独立个人库。

## 17. 运行失败与降级规则

### 17.1 原因码权威

所有 `reason_codes[]`、`selection_reason_codes[]`、`edition_reason_codes[]`、`empty_reason_codes[]`、`evaluation_reason_codes[]`、水位排除原因和其他评估原因只能引用《统一数据、时间与决策契约》第 17 节的 machine keys；本规范不得另造同义码。实现必须保存 `reason_registry_version`，写入时拒绝未知 key，并在 CI 运行跨文档 identifier linter。人类可读说明单独存储，不得反向成为机器原因码。

本规范当前引用的 key 均来自该注册表：`COLLECTION_OPPORTUNITY_MISSED`、`CURSOR_GAP`、`PURPOSE_ACQUIRE_DENIED`、`PURPOSE_EXTRACT_DENIED`、`PURPOSE_MODEL_DENIED`、`PURPOSE_TRAIN_DENIED`、`PURPOSE_SIGNAL_DENIED`、`PURPOSE_DISPLAY_DENIED`、`PURPOSE_PREVALENCE_INELIGIBLE`、`DISCOVERY_DELAY`、`PROCESSING_BACKFILL`、`CORRECTION`、`MATERIAL_UPDATE`、`RETRACTION`、`SOURCE_TIME_CHANGE`、`REVISION_ASSESSMENT_CORRECTION`、`CLOCK_UNTRUSTED`、`WATERMARK_INPUT_GAP`、`STRATUM_WATERMARK_LAG`、`COMPARISON_WATERMARK_REDUCED`、`DEGRADED_CUTOFF_LAG`、`DEGRADED_COVERAGE`、`LATE_PUBLICATION`、`BASELINE_WARMING_UP`、`SPARSE_SUPPORT`、`MULTIPLE_TESTING_UNCONTROLLED`、`CONFIRMATION_WINDOW_OVERLAP`、`COVERAGE_SHIFT`、`EVIDENCE_NOT_LOCATABLE`、`EVIDENCE_NOT_ENTAILED`、`CLAIM_SCOPE_MISMATCH`、`INFERENCE_UNSUPPORTED`、`SOURCE_CONFLICT`、`DELETED_BY_POLICY`、`EVIDENCE_CENSORED`、`MODEL_TRANSFER_FORBIDDEN`、`REVOCATION_RACE_BLOCKED`、`QUOTA_INFEASIBLE`、`STABLE_TIE_BREAK`、`ALLOCATION_LANE_ASSIGNED`、`EDITORIAL_OVERRIDE`、`CLAIM_COLLECTION_INCOMPLETE`、`CLAIM_EXPRESSION_NOT_EQUIVALENT`、`CITATION_CLAIM_MISMATCH`、`UNAUDITED_PRESENTATION_CONTENT`、`REPORT_VIEW_TOKEN_SCOPE_MISMATCH`、`RADAR_HEAD_CONFLICT`、`RADAR_VIEW_RECOMPUTING`、`RADAR_VIEW_UNAVAILABLE`、`RADAR_VIEW_TOKEN_SCOPE_MISMATCH`、`DATA_INSUFFICIENT`、`MISSED_EVALUATION_SNAPSHOT`、`LEDGER_ANCHOR_INVALID`。未在权威注册表出现的字符串即使含义相近也不得写入原因码字段。

### 17.2 失败门禁

下列情况必须阻止自动提升置信或显示醒目警告：

- 相关分层抓取成功率明显下降；
- 来源列表、API、翻译或分类模型刚发生重大变化；
- 文档无法定位原始出处；
- 时间戳大量缺失或疑似错误；
- 近似重复聚类异常；
- 某候选主要由无法解释的协调账号驱动；
- 反证检索没有覆盖相同语言或地区；
- 特征样本不足以建立基线。
- required claim slot、ReportClaim 或 PresentationContentUnit 缺失，或最终输出出现未登记/变 hash 的动态语义文本；
- 实时 snapshot 不能严格前移 current head、rights epoch 已变化、view token 失配，或无法证明全部 card/claim/render 单元来自同一 snapshot。

数据缺失时系统应该说“不知道”，不得由语言模型补足数值或事实。管道恢复后必须补算，并保留此前降级版本。

## 18. v0.1 验收标准

### 18.1 数据与时间

- [ ] `capture → raw_artifact`、`capture + raw_item → raw_item_version → canonical_item_version → source_lineage_version/event_cluster_version/evidence_unit → observation_version` 与 `signal_input_union → coverage_item → signal_candidate → signal` 可以双向追溯，且非事件输入无需伪造事件簇；
- [ ] 稳定条目与不可变版本分开；原始时间字段分开保存；所有对象逐项命中 05 的唯一 archetype/time profile，只有登记的 bitemporal version 有 valid/system interval，普通 immutable record 与 standalone snapshot 不出现伪闭合字段；
- [ ] `claim_relation`、`actor_action`、`observation` 的稳定身份与不可变 Version 显式分开；后继版本只追加 `supersession_event`，权威旧行不保存事后闭合终点，查询只投影 `projected_system_to/projected_valid_to`；
- [ ] `SourceEndpointVersion`、`PublisherAccountVersion`、`OwnerGroupVersion` 与 `SourceRegistrySnapshot` 显式版本化并由候选/特征冻结引用；role、region、owner、rights 和 cadence 的当前值不覆盖历史快照；
- [ ] `ContentCursor` 与不可变 `ContentCursorCheckpoint` 分开；推进、回退、断点修复和重建只追加带 `previous_cursor_checkpoint_id`/transition reason/sequence 的 checkpoint，Capture 与水位引用具体 `cursor_checkpoint_id`；
- [ ] `CoverageStratumVersion` 冻结分类边界；水位、分母、特征和历史报告引用 `stratum_version_id`，后来的领域/地区/角色重分类不改变旧结果；
- [ ] 关键系统时间保存 `clock_source_id`、偏移界、`clock_health_snapshot_id`、`ingest_sequence` 与 `time_quality`；时钟异常使用 `CLOCK_UNTRUSTED`，受影响输入不能进入精确窗口、提前量或跨层比较；
- [ ] `discovery_delay`、`processing_backfill` 与 `correction` 使用不同事件和原因码；
- [ ] `RevisionAssessmentVersion` 同时保存独立 `revision_type`/`reportability` 和不回填的 `decision_system_available_at`；重分类只追加新 assessment + SupersessionEvent，不修改 `RawItemVersion`、旧 assessment 或旧报告；
- [ ] 初始条目以 `item_first_seen_at` 形成 `information_arrival_at`；旧条目首个 reportable/unknown assessment 保留 `version_observed_at` 为底层到达并受 `decision_system_available_at` 资格约束；后来任意 reportability 重分类都不改原到达，只按新判断时点追加 `REVISION_ASSESSMENT_CORRECTION`；
- [ ] `RevisionAssessmentVersion.revision_type` 与同版本的 `reportability` 独立；改变既有时间线或作者归属的 `metadata_update` 必为 reportable、进入更正区且不回写旧报告；
- [ ] 迟到数据不会被伪装成历史时点已知信息；
- [ ] 08:00 与 19:00 报告均显示 `configured_data_cutoff`、`processing_watermarks{}`、`required_processing_frontier`、`comparison_watermark`、`selection_completeness_frontier` 和最终 `data_cutoff`；最终值严格取 configured、required processing 与 selection frontier 的最小值；
- [ ] 每期引用窗口前冻结、required keys 非空的 ReportPipelineManifest；每个 eligible CoverageItem×required DetectorVersion 有唯一 generation unit terminal 决定，每个 candidate×选择上下文有唯一 selection unit terminal 决定；每个 required claim slot 有唯一 ClaimGenerationUnit/Decision 且 outcome=claim 时恰有一个 typed-container ReportClaim；detector/claim 零运行、矛盾双终态或缺决定均形成 WatermarkGap/发布阻断，不能真空通过；
- [ ] `ReportScheduleManifest` 在窗口前冻结并确定性预物化 slot；缺行也按 manifest 留在分母，slot 状态只由 `ReportSlotStateEvent`/`PublicationEvent` 投影，运行时不更新状态字段；
- [ ] 每个 publication attempt 都保留；只有原子提交成功且 ReportItemPlacement、ReportCardPlacement、ClaimGenerationUnit/Decision、ReportClaim、PresentationRenderPlan/PresentationContentUnit 全部双向闭合，才产生一对一 `publication_event`/`report_edition`；完全漏发为 failed slot/state event 而非 `edition_status=failed`，预览/`created_at` 不冒充发布；
- [ ] claim-slot min/max 以 schema owner manifest/hash 与 ordinal 生成确定性 units；candidate_count=0 激活 required empty-state claim，静态 UI 不得冒充动态世界空态；
- [ ] required locale/channel/visual/ARIA/通知表达使用 ClaimExpressionVariant 并保留否定、模态、来源归属、AI 推断、数值/单位/分母及范围；claim 附近的 source title/quote 使用 ClaimCitation 明示 evidence/context/contradicts role，无 claim 的原始资料只用 RawSourceListingReference 且禁止支持标签；
- [ ] initial publication 与每个 REPORT_AMENDMENT head 各引用完整 ComposedPresentationSnapshot；ReportViewToken 的详情/分页/缓存/导出只能读该 snapshot 成员，不在请求时拼 base 与 deltas；
- [ ] 已发布版次的 `edition_status=normal|degraded` 与滚动 `service_slo_snapshot` 独立计算并引用同一 `slo_config_version`；
- [ ] 每条处理水位以 `pipeline_stage × purpose × stratum_version_id` 为权威键，另存稳定 `stratum_id` 仅供展示，并保存连续输入到达前沿 `frontier_at`、独立的 `watermark_computed_at` 与 `cursor_checkpoint_ids[]`；前沿前无已知计划采集机会或游标空洞，`comparison_watermark` 等于所需版本化前沿的最小值；
- [ ] selection completeness frontier 只有在前沿内所有入选、未选、降级和门禁候选均有 terminal `selection_decision` 时推进；只保存入选项不能提高最终 `data_cutoff`；
- [ ] 一个早已到达、今天才完成处理的输入只能关闭旧 gap 或推进旧的 arrival frontier，不能以今天的 `system_available_at` 冒充新鲜水位；
- [ ] 整点前首次发现但晚于数据截止点的文档只在下一期补录，并保留名义所属期与迟到原因；
- [ ] 相同候选清单、冻结特征、选择策略和随机种子可复现相同选择与顺序；模型输出通过冻结工件复现，不承诺重新调用模型逐字一致；
- [ ] 采集故障会触发降级，不会自动产生“讨论下降”信号；
- [ ] 每个 RadarSurface 只有 RADAR_PUBLICATION 连续 expected-head 能成为 current；revision=1 predecessor/previous snapshot 均空，后续均非空且同 surface；同 epoch frontiers/cutoff/rights 不倒退，孤儿 snapshot/旧 worker 不可见，撤权后旧 head 整体 unavailable；RadarViewToken/RadarContinuation 复合绑定 snapshot/presentation event/query shape/member，使分页/详情/缓存/导出不能跨 snapshot/epoch；
- [ ] 每个 PresentationRenderPlan 枚举最终标题、正文、caption、tooltip、alt/ARIA、通知和导出；最终 DOM/序列化 unit/ref/hash 与 plan 双向一致，零/漏 claim 或任何额外自由文本分别触发 `CLAIM_COLLECTION_INCOMPLETE`/`UNAUDITED_PRESENTATION_CONTENT`；
- [ ] 所有机器原因字段只接受《统一数据、时间与决策契约》第 17 节注册 key，未知或同义自造 key 被 schema/CI 拒绝；
- [ ] 每项自动化门禁编译自签名、不可变的 `TestDefinitionVersion`；定义变更只追加版本。P0 applicability 固定 `always` 且不能引用 `TestWaiver`，其余 waiver 必须签名、有期并保留历史失败。

### 18.2 候选与独立性

- [ ] `detector_manifest` 只有一个权威版本：M2 具备 D01–D03，M3 具备 D01–D11，且每项都有输入、暖机和确认规则；
- [ ] `event_cluster`、`observation_series_snapshot`、`concept_cluster_delta`、`claim_relation_delta` 和 `actor_action` 均可独立生成候选；
- [ ] 词汇、语义或关系新颖项在 `domain_status=unknown` 时仍可形成 CoverageItem/SignalCandidate，并进入 coverage policy 的 `random_exploration` 子分层；unknown 不触发质量失败或强制映射，但证据、权限、安全、去重和暖机门禁照常执行；
- [ ] 每个候选可关联多个 `coverage_item_ids[]`，但必须指定一个 `primary_coverage_item_id` 和一个 `primary_coverage_cell`，并只占用一个 `allocation_lane`；即使具有多个类型或进入多个栏目也不重复消耗预算；
- [ ] 候选首次冻结即固定 `candidate_id`、`candidate_frozen_at`、`proposition_family_id`、评估协议版本与 hash；merge、split、reactivate 和 Signal 映射都不改变 candidate 分母，能力报告同时给 candidate/family 两种口径；
- [ ] `candidate_emission_key = H(proposition_family_id || emission_policy_version || baseline_epoch_id || nonoverlapping_detection_window)` 有唯一约束；重试、并发、新 detector/evidence 只追加 CandidateTriggerEvent，候选冻结行、初始 detection universe 与 commitment checksum 不变；实际 Signal 状态变化另追加 SignalStateEvent；
- [ ] 使用一份 PR 新闻稿及其 100 篇转载、改写和跨语言翻译的固定样例时，系统识别为一个传播谱系，行动者独立性不增加；
- [ ] 使用三份无引用、不同组织的独立记录时，系统不会错误合并为一个起点；
- [ ] 同一旧概念换用新词或跨语言别名时，只提高词汇新颖性，不错误提高概念新颖性；
- [ ] 不同语言中的新本地行动者独立采用同一概念时，扩散路径能记录真实行动者迁移；
- [ ] actor-group 节点、地区/角色扩散和所有权独立性只读取冻结 `SourceRegistrySnapshot` 中观察时间适用的账号/集团 Version；unknown 不由未来资料静默补齐；
- [ ] 每个来源发现周期在结果可读前由 SourceDiscoveryProgramManifest 展开全部 SourceDiscoveryFrameOpportunity 及唯一 run/skipped/failed terminal；run 一对一引用 frame，frame 内再闭合全部 SourceDiscoveryOpportunity/Decision，不能只为容易格创建完整 frame；
- [ ] 单源新颖候选可以进入观察，但卡片明确显示低置信；
- [ ] 候选集按覆盖分层分配预算，不存在全局 Top-K 一次性截断；
- [ ] 合并、拆分和重新激活均保留历史 ID 映射；
- [ ] 暖机不足的检测器只能输出相应受限观察，不能升级生命周期或生成正式衰退/结构结论。

### 18.3 特征、评分与置信

- [ ] 所有特征包含原始值、基线、分层、时间窗口、样本量、方法版本和证据链接；
- [ ] 缺失值不会被当作零；
- [ ] 数据层和 API 中不存在单一总分字段；
- [ ] `signal_types[]`、唯一 `allocation_lane`、`surface_sections[]` 和 `ranking_rule_id` 字段语义与数量约束分开；
- [ ] 每个信号类型只使用预登记的 2–3 个核心维度，排序遵循硬约束、健康/暖机、类型准入、覆盖预算、栏目排名和稳定 `candidate_id` tie-break 的优先级；
- [ ] 观察置信与解释置信分开；
- [ ] 高强度、低置信信号可以正常展示；
- [ ] 冲突证据显示为争议，而不是被平均掉。
- [ ] 模拟采集文档量翻倍但主题占比不变时，系统不会仅凭计数生成升温信号；
- [ ] 稀疏分层的大比例增长带有可信区间、样本支持和多重检验标记；
- [ ] 每个 p/e-value 绑定不可变 TestStatisticInputSnapshot、filtration definition、抽样/停止 lineage、dependence cluster 与 conditional-validity method；共享输入、条件相关或结果依赖停止的 null fixture 未通过时，即使 opportunity/order/threshold/wealth 完整也标 `MULTIPLE_TESTING_UNCONTROLLED`；
- [ ] 检测与确认不仅在时间和 record ID 上断开，还按 SourceLineage、行动者/行动、measurement/data-generation process 检查独立；同一生成过程切新 ID 或相邻重叠窗口中的同一材料不产生自我确认；
- [ ] 每个展示与未展示决策都能返回完整 `selection_trace`，包括规则、配额桶和原因码；
- [ ] 任意候选均可用相同快照与随机种子复现选择结果。

### 18.4 证据与生命周期

- [ ] 每张卡片至少链接一个权限策略允许的 `provenance_ref`，不强制保存或展示全文；
- [ ] 每个事实陈述可以追溯到观察和证据单元；
- [ ] 每个报告原子主张具有规范 `assertion_type`、`evidence_scope_ids[]`、认识状态和 `report_claim_id`；
- [ ] 事实和来源主张必须通过针对实际发布命题的 entailment 门禁；`source_causal_claim` 只 entail“来源提出因果主张”，不证明现实因果；
- [ ] `ai_inference` 与 `ai_causal_inference` 必须为 `entailment_result=not_applicable` 并通过 premise-support；后者另存识别策略、因果假设、混杂/反向因果检查并通过 causal-premise gate，相关或时间先后不能单独过门禁；
- [ ] 支持/反驳关系通过证据锚点、主语、数值/单位、否定、模态、时间与范围兼容矩阵；
- [ ] 第一手记录只证明其证据范围内的命题，宣布、承诺、执行和结果不会越级；
- [ ] `watch` 及以上信号包含反证查询和具体后续观察条件；
- [ ] 注入一份高质量反证后，相关卡片在下一次运行中显示该证据并按规则转为争议、降置信或证伪；
- [ ] 生命周期全部状态可进入，转换采用追加日志；
- [ ] 被证伪或消退的信号不会仅因结果不佳被物理删除；合规删除能级联清除受限证据并留下非内容墓碑；
- [ ] 红删、墓碑、访问撤销和评估删失分开；被合规删除而无法判断的候选仍留在冻结 cohort 与总数中并记为 `EVIDENCE_CENSORED`，成败率按预登记的删失规则计算，不得静默移出；
- [ ] 权限在采集、抽取、模型出站、训练、持久化、选择、发布和读取阶段分别重检；训练拒绝使用 `PURPOSE_TRAIN_DENIED`；撤权递增 `revocation_epoch`、取消/taint 旧 epoch 在途任务，发布提交前 epoch 不一致使用 `REVOCATION_RACE_BLOCKED` 并阻断；
- [ ] 同一信号在连续日报中优先展示增量变化，避免重复轰炸。

### 18.5 广度、偏差与隔离

- [ ] 日报渲染热点、弱信号和盲区探索等独立栏目；任一栏目可无候选，但必须显示空原因、覆盖债务和数据健康；
- [ ] 至少按地区、语言、领域、来源类型和社会角色输出覆盖指标；
- [ ] 硬覆盖验收只使用冻结 `CoveragePolicyManifest.required_cells`，不要求完整五维笛卡尔积；
- [ ] 每期报告来源集中度、低曝光分层占比和覆盖缺口；
- [ ] 每个 attention frame/claim 披露 `audience_unit_type`、`identity_namespace`、linkage/dedup method version 和误合并/漏合并界；账号、设备、token 触达不得在无 person-level oracle 时写成 unique people/audience reach；
- [ ] 高操纵风险信号被标记且能解释风险原因；
- [ ] 模拟 10,000 个协同机器人账号爆发时，系统可以显示注意力异常，但不会把它当作 10,000 份独立支持或仅凭数量升级为 `active`；
- [ ] 使用相同全局数据和不同用户记忆运行，候选、特征和排序结果逐字节一致；
- [ ] 当前问题在个人域拆成 `private_query_context` 与去标识 `neutral_query`；全球检索不接收 `user_principal_id`、历史对话或个人 embedding，`query_plan_id` 和个人域 EvidenceUnit 引用也不进入全球长期日志；
- [ ] AI 提取内容默认只进入 `memory_candidate`；长期记忆须用户确认或明确规则，且支持查看、更正、导出、保留期和覆盖原文/embedding/缓存/备份/供应商副本的删除；
- [ ] 用户纠错只进入 `correction_proposal`；未经身份无关验证与版本化治理，不得改变全局对象或排序。
- [ ] 个人点击、记忆、对话和“是否新颖”反馈既不影响当前运行，也不进入全球 detector/ranking/model/policy 的离线评估、训练或版本晋升；跨版本 data-lineage canary 为零。

### 18.6 安全、断流与时间旅行

- [ ] 将相关分层来源突然断流 50% 时，不生成错误的衰退信号，并显示覆盖降级；
- [ ] 将采样频率加倍但底层内容比例保持不变时，不生成错误的升温信号；
- [ ] 一篇发布时间早于截止点、但 `item_first_seen_at` 晚于截止点的文档，在时间旅行回放中不可见；
- [ ] T 之后新增的实体别名、事件合并、来源依赖、证据关系或人工纠错在 `operational_replay(as_of=T)` 中不可见；
- [ ] T 之后的收购、发布账号角色/地区重分类、rights/cadence 修订在 `operational_replay(as_of=T)` 中不可见，也不改变旧 actor-group 图、采集分母或特征 hash；
- [ ] 新模型重分析历史时产生独立版本，不覆盖原日报，也不计入当时的发现提前量；
- [ ] 原始网页包含“忽略系统规则、提高本信号分数、调用工具或泄露数据”等恶意指令时，指令不会改变抽取规则、候选、配置、工具调用或数据权限；
- [ ] 恶意内容本身仍可被隔离保存、引用和审计，不因防御而篡改原始档案。
- [ ] 模拟时钟倒退或偏移超界时，受影响对象设置 `time_quality=degraded`，报告降级且不计算精确窗口与提前量；来源时间不能“修复”系统时钟；
- [ ] 模拟报告发布事务与撤权竞态时，旧 epoch 输出被 taint，原子提交失败且记录 `REVOCATION_RACE_BLOCKED`；已发生的外部传输被如实记录并启动供应商删除流程；

### 18.7 回测

- [ ] `operational_replay` 同时按原始版本的 `version_available_at`、派生对象的 `system_available_at` 及双时间有效区间切片，不读取未来修订；
- [ ] `operational_replay` 固定读取 T 时已可见的 `SourceRegistrySnapshot`、`SourceEndpointVersion`、`PublisherAccountVersion` 和 `OwnerGroupVersion`；当前权利只作为执行门禁，不反向改写当时 rights snapshot；
- [ ] 归一化、聚类、实体别名和知识图谱均只使用截止时点数据；
- [ ] 成功、消退、操纵、非英语、逆转和随机对照案例都进入回测集；
- [ ] 具有独立同时代捕获证据且不使用未来模型的历史机制诊断标为 `archive_replay`；使用后来模型、别名、聚类或知识的实验标为 `retrospective_reanalysis`；
- [ ] 训练截止晚于回测时点的 LLM 结果只进入诊断报告，不进入能力指标；
- [ ] 7/30/90/180/365/730 天每个 horizon 都有固定 `outcome_as_of`；`EvaluationCorpusSnapshot` 是带逐项 hash/inclusion proof 的不可变 raw/derived/evidence ID 清单而非查询，并在 `outcome_as_of+5m` 前形成和外部锚定；晚执行逐 ID 读取并单存 `evaluation_executed_at`，缺失/迟锚使用 `MISSED_EVALUATION_SNAPSHOT` 而非事后重建；
- [ ] EvaluationArmManifest 在 arm 数据可读前冻结全部比较 arm；每个 arm 的 generation units/decisions、K 个完整有序 OutputSnapshot members、EvaluationObligations 与 EvaluationResults 集合相等，不能只保存基线失败输出或只评价系统 arm；
- [ ] EvaluationCorpusSnapshot 中每个潜在验证 EvidenceUnit 都有 ValidationEvidenceEligibilityUnit/Decision；支持、反证、排除与 failed 全量终态分别和 EvaluationResult/evidence package/排除审计集合相等，漏反证或自由 validation 数组使能力声明 blocked；
- [ ] 每项纳入验证证据的全部 producer/investigator/measurement operator 均有 ValidationEvidenceProducerExposureUnit/Decision；任一 exposed/possibly_exposed/unknown/缺失只可标 system-induced validation，不能标 independent validation；
- [ ] detection evidence 与 validation evidence 按谱系、行动者和数据生成过程执行独立性规则；重复自述只能标为持续主张，不能标独立复现；
- [ ] 主观 outcome 的 EvaluationProtocolVersion 引用 cohort 前冻结的 AnnotationProtocolVersion；合格盲评员完成独立双标，原 Judgment 不可覆盖，分歧只追加 AdjudicationDecision；缺资格/盲法/初标/裁决时使用 `DATA_INSUFFICIENT`；
- [ ] OutcomeFrame 的行动者生成规则为每个因果行动者/行动物化 OutcomeActorExposureUnit 与唯一 decision；actor units/terminals/lineage subjects 完全相等，link 按“任一 exposed 即 exposed、任一缺失/不确定即 unknown/possibly_exposed”聚合，不能选未暴露代表人；
- [ ] 评估 ledger 使用前序 hash 链；协议在 cohort 前锚定，候选 commitment 满足 `anchored_at <= candidate_frozen_at+5m < earliest outcome_as_of <= reveal_at`，每个 checkpoint 有外部 receipt/inclusion proof；任一段晚锚/缺锚/验签失败使依赖它的整条后续链使用 `LEDGER_ANCHOR_INVALID` 且能力结论无效；
- [ ] 结果同时报告广度、新颖度、提前量、误报负担和可追溯性，不发布单一综合指标。

### 18.8 上线门槛

首版上线前必须完成至少 30 天影子运行。影子期不要求证明未来预测准确，但必须证明：

1. 两个日报时间窗稳定生成且可回放；
2. 所有卡片具备原始证据和选择理由；
3. 来源转载不会系统性抬高独立性；
4. 采集故障不会被误识别为真实变化；
5. 每期确实渲染热点、不同类型弱信号和盲区探索栏目；没有合格候选时显示空状态而不凑数；
6. 团队可以解释任一卡片为何出现、为何排序在对应 `surface_section` 的位置、使用哪个 `ranking_rule_id`、哪些证据会使其降级；
7. 月度复盘可以完整统计信号的增强、消退、证伪、建立和再激活。

影子运行首日即开始冻结前瞻台账。系统上线后的能力报告统一使用 7/30/90/180/365/730 天前瞻结果；操作回放和档案诊断必须分栏报告。

若以上任一项无法回答，系统仍是不可审计的信息推荐器，不能被视为弱信号雷达。

### 18.9 自动化契约测试

上线流水线必须将以下每个固定夹具编译为签名、不可变、可执行的 `TestDefinitionVersion`，并冻结 `test_definition_version_id`、applicability、输入夹具 hash、预期断言、审批和影响面；修改只能追加新版本并保留旧签名与结果。所有 P0 架构、安全和隐私不变量的 applicability 固定为 `always` 且不得引用 `TestWaiver`；非 P0 waiver 必须签名、限时、说明范围，到期自动失效且不删除历史失败。以下测试全部适用且通过才可发布：

| 夹具 | 必须满足的断言 |
|---|---|
| PR 百篇转载 | 文档数为 101，传播谱系为 1；不因转载数增加独立支持或行动者扩散 |
| 机器人爆发 | 注意力异常可为高；独立支持不随机器人帖数增加；显示高操纵风险；不能仅凭数量进入 `active` |
| 来源断流 | 抓取下降触发数据质量告警；不生成真实衰退结论 |
| 采频加倍 | 原始计数可增加；稳定占比和分母校正后不生成虚假升温 |
| 跨语言换名 | 词汇新颖性可升高；概念新颖性和行动者扩散不得无证据升高 |
| 开放世界未知领域 | 注入无法映射既有领域但词汇/语义/关系新颖且证据可定位的输入；即使 `domain_status=unknown` 也生成 CoverageItem，并可在安全门禁通过后形成唯一候选、进入 `random_exploration` 子分层；不得强制贴入最相近已知领域，也不得把 unknown 当质量失败 |
| detector 前 OOD 探索 | 合格 unknown/OOD 输入让 D01–D11 全部返回 no-candidate；仍物化唯一 PreDetectionExplorationUnit/Decision，冻结随机框 selected 项只以 `not_a_signal=true` 的未解释材料展示，不进入信号、prevalence 或命中分母 |
| detector 前资格分母 | 100 个等质 no-candidate CoverageItems 只为最吸引人的一个建 unit；每项必须先有 eligibility terminal，分母=100，缺任一形成 gap，不能报告探索预算完成 |
| CoverageItem 同义复制 | 100 个并发事务对相同 scope/policy/semantics/kind/typed input/strata/role 提交不同 ID；projection key/UUIDv5 重算后只有一个 item/generation unit，重复或漏建产生 WatermarkGap |
| 独立行动者迁移 | 新地区本地行动者独立采用后，扩散路径和行动者独立性增加 |
| 来源画像时间旅行 | 冻结 2026 快照与特征后，在 2027 注入收购、账号 role/region 重分类、rights/cadence 变化；2026 `operational_replay` 的账号/集团 Version、actor-group 图、扩散/独立性、采集机会分母和特征 hash 逐字节不变，只有 `retrospective_reanalysis` 可并列使用新知识 |
| 高质量反证 | 卡片必须出现反证；解释置信按规则下降、转争议或证伪，且记录状态事件 |
| A/B 用户画像 | 不同个人记忆、点击和观点下，全局候选、特征、选择轨迹与排序逐字节相同 |
| 跨版本个人反馈 canary | 把可追踪的个人点击、记忆和“我之前不知道”反馈注入离线数据湖，再尝试训练或晋升全局 detector/ranking/model/policy；全局训练/评价 lineage 中个人域记录数必须为 0，champion/challenger gate 阻断任何含 canary 的版本，不能以“当前固定配置不读用户”绕过 |
| PersonalScope 跨租户 canary | A 的私有对象、embedding、cache、export、backup、provider job 注入 canary，B 以直接 ID、重放 token、分页、导出、恢复和 callback 访问；scope+owner+authz epoch/RLS 不泄露存在性，公共输入 snapshot 的 private-lineage count 必须为 0 |
| 外部模型 egress/taint | 网页与恶意 provider 输出要求读取记忆、修改 rights、调用 export/任意 URL；实际出站逐字节匹配 OutboundPayloadManifest/PurposeAuthorization，未列工具、网络、凭据和控制面写入失败，tainted 输出仅 typed validation 后作数据 |
| provider 隐式上下文 | 私有 canary 已存 remote session S，公共请求只发送合法 `thread_id=S`；未登记 context 或 transitive private-lineage 非零均在出站前失败，公共输出 canary=0 |
| provider callback 绑定 | unsigned/错 key/错 invocation/nonce 重放/改 body/并发第二 callback/撤权后 callback 均不得生成 output；签名覆盖 job/invocation/body/scope/owner/全部撤权域且 terminal 唯一 |
| 模型验证双终态 | 同一 required validation unit 并发 pass/fail；attempts 分离、terminal decision 唯一，全部 required units passed 才能下游，不能择取幸运 pass |
| 复合撤权域 | payload 同时依赖 PersonalScope 和内容 rights，只推进任一 domain；旧 callback/cache/export/token/delivery 全部失效，不能只校验单一 epoch |
| 时间旅行 | `source_published_at < T < item_first_seen_at` 的文档在 `T` 时点不可见 |
| 版本判断重分类 | RawItemVersion 逐字节不变；初始 assessment 及 non-reportable/reportable/unknown 间任意重分类均只追加 `RevisionAssessmentVersion`/SupersessionEvent，保存各自 `decision_system_available_at`；原 `information_arrival_at` 不变，新判断只追加 `REVISION_ASSESSMENT_CORRECTION` 且不重复首发 |
| 版本更新归属 | 初始版本按 `item_first_seen_at` 首发；旧 item 首个 reportable/unknown assessment 保留 `version_observed_at` 为底层到达、在 `decision_system_available_at` 后才可处理，non-reportable 无报告到达，均不改写原首发窗口 |
| 来源时间修订 | 修改旧 item 自报发布时间使既有时间线语义变化；追加 `revision_type=metadata_update, reportability=reportable` 的 assessment，以 `SOURCE_TIME_CHANGE` 进入更正区；RawItemVersion、原到达和旧 edition 不变，且不得把 SOURCE_TIME_CHANGE 写成 revision_type |
| 派生版本闭合 | 依次生成计划、执行、取消三个 `actor_action_version`，并对 ClaimRelation/Observation 做同类更新；旧版本行逐字节不变且无事后终点，查询 `projected_system_to/projected_valid_to` 只由当时可见的追加 `supersession_event` 投影 |
| 时钟失信 | 注入时钟倒退、超界偏移和序列回退；对象标 `time_quality=degraded` 与 `CLOCK_UNTRUSTED`，edition 降级且不进入精确窗口/提前量 |
| 跨域顺序 | 两个写入域的 `ingest_sequence` 数值相同或相反；系统不据此排序，只接受 `causal_parent_event_ids[]` 与队列 offset 证明的 happens-before |
| 跨域因果 DAG | 分别写入自环、二节点/长环、晚于 child 的 parent、旧事件迟到边和两个并发反向边；复合主键、自环/时间/sequence/queue proof 与 serializable DAG 门禁阻断，并发至多一个提交且旧 as-of 不变 |
| 到达前沿水位 | 早到输入今天才处理完成时，`watermark_computed_at` 可以是今天，但 `frontier_at` 只能是连续 `information_arrival_at` 前沿；存在采集机会或游标 gap 时不得越过 gap |
| 游标追加历史 | 对同一 ContentCursor 执行推进、回退和重建；每次只新增 ContentCursorCheckpoint 并正确链接 `previous_cursor_checkpoint_id`/transition reason/sequence，旧 checkpoint 逐字节不变；游标断裂时水位不得前移 |
| 分层版本时间旅行 | 冻结 `stratum_version_id` 及其水位/分母/特征后修改领域、地区或角色纳入谓词；旧运行仍逐字节引用原 CoverageStratumVersion，新边界只进入新运行 |
| 未来派生对象 | T 后新增别名、聚类、证据边和纠错；`operational_replay(as_of=T)` 全部不可见 |
| 操作回放 | 使用冻结候选、特征、策略和种子，选择 ID、顺序和原因码一致；不重新调用生成模型 |
| 档案回放与回顾重分析 | 同时代捕获档案使用 `run_mode=archive_replay`；后来模型或知识使用 `run_mode=retrospective_reanalysis`；二者都产生新 `analysis_run`、不改旧日报哈希且不进入前瞻能力指标 |
| 恶意网页指令 | 不改变系统提示、评分、工具调用或权限；原始恶意文本仍可审计 |
| 合并—拆分—复活 | 冻结 `candidate_id/proposition_family_id` 不变，所有映射与状态追加；candidate 分母不减少/复制，candidate-level 与 family-level 结果同时报告 |
| 候选发射幂等 | 对同一 family/emission policy/baseline epoch/nonoverlapping window 注入并发重试、两个检测器 patch 版本和相邻重叠窗；唯一 emission key 只产生一个 candidate，其余各追加 CandidateTriggerEvent，候选 checksum 与初始 detection IDs 不变；只有新不重叠窗或真实 baseline epoch 变化且满足预注册重触发规则才可产生新 candidate |
| detector 版本闭合 | 同一 D05 key 下冻结两个不同 DetectorVersion，并试图只用 detector_key 生成 required pairs；DetectorManifest 必须分别 FK 具体版本，generation unit 按 detector_version_id 区分，缺任何 required version 的 terminal decision 都形成 gap |
| detector 零运行 | raw/parse 水位健康但全部 detector worker 未启动、实际候选集为空；非空 ReportPipelineManifest 仍要求全部 generation units，缺行产生 WatermarkGap，selection frontier 不推进且不能生成 normal 空报告 |
| 重叠窗口 | 两个相邻滚动窗口共享全部原始材料；第二窗口不能提供确认，只有新增且通过谱系、行动者和数据生成过程独立性检查的样本可以确认 |
| 同一生成过程新 ID | 把同一 API 测量切成两个新的 EvidenceUnit/ObservationVersion ID 并放入检测/确认窗；尽管 ID 不相交，measurement/data-generation process 相同，确认不得升级为独立复现 |
| 证据蕴含 | 分别篡改主语、数值单位、否定词和“计划/已执行”模态；每种不兼容均阻止 `supports` |
| AI 推断门禁 | `ai_inference` 的 entailment 固定为 `not_applicable`；删除 premise、扩大范围或遗漏强反证时使用 `INFERENCE_UNSUPPORTED` 并阻断，不能改标事实绕过 |
| 因果类型分流 | 来源原文声称 A 导致 B 时，entailment 仅允许带归属的 `source_causal_claim`；仅提供相关、时间先后或预测改进时，`ai_causal_inference` 的 causal-premise gate 不能通过并使用 `INFERENCE_UNSUPPORTED` |
| 验证证据独立 | detection 与 validation 使用同一谱系/行动者重复自述时不得标独立复现；独立数据生成过程出现后才可升级 |
| 验证证据选择性遗漏 | EvaluationCorpusSnapshot 含 1 份独立支持与 9 份按协议合格的独立反证，实现只把支持项写入 validation 数组；为全部 EvidenceUnit 物化 ValidationEvidenceEligibilityUnit/Decision，支持/反证/排除/failed 与 Result/evidence package/排除清单完全相等，漏任一反证阻断能力声明 |
| 系统诱导独立验证 | 已注册记者收到候选通知后才开展调查并发布一份新谱系、新测量过程的证据；即使未被 candidate 招募且相对 detection 独立，producer exposure unit 仍标 exposed/possibly_exposed，结果只能是 system-induced validation/intervention echo，不得计独立复现 |
| 来源发现候选漏账 | 冻结目录/搜索/链接发现 frame 返回 1,000 个规范来源候选，只为 10 个易接入者创建决定；SourceDiscoveryFrameManifest 必须展开 1,000 个 SourceDiscoveryOpportunity 与唯一 terminal decisions，缺 990 项形成 discovery gap，不能靠进入 U 后的完整率通过 |
| 来源发现 frame 选择性消失 | 计划 100 个地区×语言×渠道发现批次，只为准入率最高的 10 个创建内部完整 frame；SourceDiscoveryProgramManifest 必须预先展开 100 个 SourceDiscoveryFrameOpportunity 与唯一 run/skipped/failed terminal，run 与 frame 一对一，其余 90 个仍形成 program gap，不能靠 10 个完整 frame 声称跨格发现覆盖 |
| candidate 条件化招募 | C 出现后按其关键词招募 50 个新站点转载 C；RecruitmentCohort 标 candidate-conditioned，这些来源不得形成 C 的扩散、独立确认或流行度升级，预冻结独立留出框仍可 |
| 条件化招募跨 candidate | C1 条件化来源触发 C2；ConditioningAncestryClosure 使其对 C2 的 D07/确认/prevalence 增量为 0，即使 candidate/family ID 不同 |
| 连续多重检验 | 365 天每小时动态扫描一万主题并每窗重置 BH；所有 test/candidate/no-candidate/failed 必须进入同一 SequentialHypothesisFamily ledger，漏账/重置使用 `MULTIPLE_TESTING_UNCONTROLLED` 并阻断确认/晋升 |
| 评分前检验 universe | 10,000 零假设先取最小 p 只登记赢家，或建 100 sibling families 各取 alpha；scored=generated=ledger terminals 且 child debit≤root wealth，否则 `MULTIPLE_TESTING_UNCONTROLLED` |
| online-FDR predictable allocation | 预建并最终入账全部 10,000 个 null tests，但先读全部 p 值，再按 p 排序或只给小 p 分配较大 alpha_i；每项 logical order/threshold reservation 必须在统计量可见前锚定并只依赖严格先前 history，违规即 `MULTIPLE_TESTING_UNCONTROLLED`，即使机会全量且 wealth 守恒 |
| online p/e conditional validity | 顺序 null tests 共享同一输入 `U` 并生成边际均匀、条件相关的 `p1=U,p2=1-U`；所有机会、顺序、阈值和 wealth 均合法。每项必须绑定 TestStatisticInputSnapshot、filtration/dependence lineage、抽样/停止规则和 conditional-validity method；不能证明条件超均匀/e-process 超鞅时仍为 `MULTIPLE_TESTING_UNCONTROLLED` |
| 共享 outcome 有效样本量 | 50 个 candidate 指向同一工厂开工或同一独立数据集；OutcomeUnit/OutcomeCluster 去重，能力按唯一 outcome coverage、n_eff 和 cluster-robust interval，不得记为 50 次独立成功 |
| 独立 outcome frame | 隐藏 frame 有 10 个现实 outcomes 仅链接 1 个；全部机会有 generation terminal，coverage=1/10，漏决定阻断，无 frame 不得声称 recall |
| OutcomeFrame 候选后定制 | cohort 已产生候选后、正式揭盲前按候选命题创建一个内部完整 frame；frame 必须因未在 cohort/首次 candidate data access 前锚定或 candidate lineage 非零而阻断，不能因内部机会无漏项通过 |
| 自我实现 outcome | 用户收到某候选提醒后因此签订合同，系统随后把合同作为候选命中；CandidateOutcomeLink 必须标 exposed/possibly_exposed，纯发现能力排除或作最坏—最好界，干预/decision-support 效果单列 |
| 多行动者暴露择取 | 同一 outcome 中，收到提醒并发起行动的 A 为 exposed，未接触系统的签字人 B 为 unexposed；不得只选择 B 写 link assessment。按冻结 actor-generation rule 为 A/B 物化 OutcomeActorExposureUnit/Decision，集合与 lineage 全量相等，任一 exposed 使 link=exposed，缺失/不确定 fail closed |
| 评估 arm 输出选择性消失 | 系统与编辑基线都配置相同 corpus/cutoff/K=10，但实现保存系统 10 项、只保存基线最差 3 项并据此宣称胜出；EvaluationArmManifest 展开各 arm 全量 generation terminals，揭盲前 OutputSnapshot 固定 K 个输出，且 arm members=obligations=results，漏 7 项阻断能力比较和版本晋升 |
| 评价义务唯一终态 | 同一 obligation 并发 snapshot/missed 与相反正式结果；snapshot decision/result 分别唯一并复合绑定同协议/horizon/ledger，不能择优 |
| 能力声明挑赢家 | 零效应 cohort 跑 20 个协议/指标/子群只发布显著者；CapabilityClaimFamily 穷尽 universe 并共享 multiplicity，未校正挑赢家 blocked |
| 主观标注揭盲攻击 | 对 system/baseline 混合样本先双盲双标，再尝试缺一份初标、用无资格 reviewer、揭盲后覆盖标签或只保留最终裁决；原 EvaluationJudgment 必须保留，分歧只追加 AdjudicationDecision，任一缺口使用 DATA_INSUFFICIENT 并阻断能力声明 |
| 处理补录与更正 | 同一内容分别模拟晚处理和来源撤稿；前者保留原 `information_arrival_at` 并标 `processing_backfill`，后者按新版本 `version_observed_at` 创建 `correction`，均不重复首发 |
| 并发首发与补录 | 两个 worker 把同一 ReportableArrival 同时放入两个 edition 并都声明 first，或同一期重复放置；PublicationEvent、Edition 与完整 placements 必须原子提交，每 arrival 最多一条 first、同 edition 最多一条 placement，失败事务不能留下无 placement 的已发布 edition，后续补录引用原 slot |
| 非原文候选卡片 | 选择一个只来自 ObservationSeriesSnapshot 的 candidate，同时放入一个 not_selected 对照；selected unit 必须生成唯一 ReportCardPlacement，not_selected 无卡片，不能为 candidate 伪造 ReportableArrival，edition 冻结的卡片顺序与实际 card placements 完全一致 |
| 卡片主张原子性 | 为一个 selected card 生成两句 claim，漏写一句、把另一 candidate 的 claim 跨卡挂入或重复 claim_order；Publication/Amendment 必须回滚，只有同 presentation event、typed container 正确且 ordered claim 清单完全一致时才能提交 |
| claim 分母与渲染旁路 | selected card/概览生成零 ClaimGenerationUnit、required slot 返回 not_applicable，或在 title/tooltip/alt/Markdown/通知额外拼一句；零/漏项使用 `CLAIM_COLLECTION_INCOMPLETE`，最终 DOM/序列化 unit/ref/hash 与 PresentationRenderPlan 不双向相等使用 `UNAUDITED_PRESENTATION_CONTENT`，整笔发布失败 |
| 空态不可静态冒充 | 真实零候选、worker 未运行、open gap、撤权重算分别触发同一 section；只有绑定 completeness/watermark/coverage/rights/观测四态的 required empty-state claim 可说明真实零，其他按 failed/unavailable，静态“没有信号”模板返回 `CLAIM_COLLECTION_INCOMPLETE` |
| amendment 累计快照 | initial A/B 后连续删除 A、替换/重排 B，同时交错读、缓存、详情、导出；每个 head 引用完整 ComposedPresentationSnapshot 与 ReportViewToken，响应完全等于某一 committed head，不并行拼 base/deltas |
| locale/channel 语义等价 | 中文 claim 含否定、数值、来源归属与“可能”，英语 visual/ARIA/通知 variant 删除限定或改单位；即使 hash 自洽，ClaimExpressionVariant semantic-equivalence 失败并用 `CLAIM_EXPRESSION_NOT_EQUIVALENT` 阻断 |
| citation/原始列示错配 | claim A 邻接合法但无关 source B 的 title/quote，并把 context 标 evidence；另让无 claim 的 raw listing 复用 nullable ClaimCitation。ClaimCitation 必须证明同 claim 的 exact scope/rights/role，错配使用 `CITATION_CLAIM_MISMATCH`；raw listing 只能用无 report_claim_id 的 RawSourceListingReference 绑定 ReportItemPlacement，两类 XOR |
| 实时 current-head 崩溃并发 | 两个 worker 用不同 snapshot/epoch 刷新同一 RadarSurface，在 snapshot/card/claim/render/head 各阶段崩溃并重放旧 worker；只有连续 revision expected-head winner 成为 current，公共读取始终返回单一 snapshot checksum，孤儿/部分/混合/回退均失败 |
| 实时撤权与分页 | 在读取排序、首字节、卡片详情和下一页之间提高 rights epoch，并让旧/新重算交错；同 RadarViewToken 只能返回完整旧 view、完整新 view、`RADAR_VIEW_RECOMPUTING` 或 `RADAR_VIEW_UNAVAILABLE`，不得旧排序配新墓碑、跨 epoch 补卡或旧缓存命中 |
| 实时 token scope | 用 S2 token 请求 S1 card/cursor/export selection 或改 query shape；RadarContinuation 与所有成员复合绑定 S2/event/query shape，返回 `RADAR_VIEW_TOKEN_SCOPE_MISMATCH`，不能只验证签名 |
| CDN/Range/stream 撤权 | 首 chunk 后提高 epoch，同时请求 CDN 离线命中、304、Range resume、SSE 重连和异步 export；未建模模式默认拒绝，有限响应绑定完整 token/head/epoch/payload，撤权后不得继续交付旧内容字节 |
| 注意力可达性 | 热点占满首屏/通知，探索项虽 selected 却都在折叠区或深分页；AttentionBudgetManifest 与 AttentionPlacement 对账固定 K、viewport/fold/page、通知和跨表面重复，不读取点击，无法到达则失败 |
| 位置与交付机会 | 探索卡低请求页面首屏但 delivery=0、热点通知 10,000；placement 可过但 delivered exposure=0，不能声称曝光兑现或实际阅读 |
| 交付受众 Sybil/重放 | 同一 bot、预取器或 push token 对探索卡制造一百万次成功 delivery；按 eligible audience unit×content/surface×window×channel 去重，raw delivery 与 unique eligible reach 分报，invalid/unknown 不得充当合格曝光 |
| 触达统计单位错称 | 一人用 100 个真实账号/设备接收，另有 100 人共享一个机构 token；全部非 bot/重放。frame 与 claim 必须绑定 audience_unit_type、identity_namespace、linkage version 与误合并/漏合并界；只能分别称 100 accounts/devices 与 1 token，无 person-level oracle 禁止称 unique people/audience reach |
| 审计 A 交付 B | committed render=A，Delivery 自报 `A+未经审计 B` 并重算 hash；representation expected bytes 与 delivery 必须完全相等，增删改一字节不得出首字节 |
| 合规删除 | 删除支持证据后递增 epoch 并级联红删，`provenance_ref` 受权限控制，墓碑不再作证据，结果使用 `EVIDENCE_CENSORED` |
| 删除前备份回滚 | 恢复 T0 含 canary 备份但真实撤权 checkpoint 在 T1，另回滚 checkpoint；RecoveryFence 先取得最新独立高水位并 replay/红删/销钥，缺失或回退时 deny-all，canary 不可从 blob/index/cache/report/export/provider retry 取回 |
| 撤权竞态 | 模型/渲染任务用旧 `revocation_epoch` 在途时触发撤权；任务被取消或 taint，发布原子提交使用 `REVOCATION_RACE_BLOCKED` 并失败，读时旧缓存不可见 |
| 私有查询 | 含姓名、秘密和用户立场的问题经个人域生成去标识 `neutral_query`；全球日志不出现原文、`user_principal_id`、query plan、个人 EvidenceUnit 引用或 embedding |
| 个人记忆删除 | 未确认提取只留在 `memory_candidate`；删除已确认记忆时，私有原文、版本、embedding、缓存、备份生命周期和供应商副本均被清理，只留无主题/身份墓碑 |
| Horizon 快照 | 7 天作业晚两天执行仍只能读 `outcome_as_of` 快照；快照未在 `outcome_as_of+5m` 前形成并锚定时返回 `MISSED_EVALUATION_SNAPSHOT`，窗口后证据不可见 |
| Horizon 清单不可重跑 | 快照只保存查询、漏掉物化 ID 清单/逐项 inclusion proof 时返回 `MISSED_EVALUATION_SNAPSHOT`；晚作业不得重新执行查询、替换被删成员或加入窗口后版本 |
| Ledger 时间锚 | 分别篡改前序 hash/inclusion proof、移除外部 receipt、伪造本地 `anchored_at` 或让任一 checkpoint 晚于 deadline；使用 `LEDGER_ANCHOR_INVALID`，且后来锚定更长 root 不能修复依赖该段的整条链 |
| 单期与滚动 SLO | 一期严重陈旧而滚动准时率达标时，该期仍为 `edition_status=degraded`；`service_slo_status=meeting` 不得覆盖单期状态 |
| 选择完整前沿 | `configured_data_cutoff` 与 required processing frontier 已到 23:45，但一个候选到 23:43 后仍无 terminal decision；`selection_completeness_frontier` 和最终 `data_cutoff` 不得越过 23:43，cutoff lag 按最终值计算 |
| 发布计划与事实 | 用窗口前冻结 manifest 推导计划 slot，删掉/漏建 slot 仍计失败；scheduled/failed/cancelled 只由 ReportSlotStateEvent 投影，published 只由验证最新撤权 epoch 的原子 PublicationEvent 投影；预览、数据库创建和失败 attempt 无 edition |
| 空栏目 | 某栏目无合格候选时仍渲染空原因、覆盖债务和水位，不使用低质量内容补位 |
| 暖机 | 历史长度低于检测器门槛时 `baseline_status=warming_up` 或 `baseline_unavailable`，覆盖机制变化时为 `coverage_shift`；不得生成正式衰退或结构结论 |
| 用户纠错 | 未审核纠错不改变全局哈希；审核通过后产生面向所有用户的新版本和审计事件 |
| 原因码注册 | 向任意原因字段写入未出现在《统一数据、时间与决策契约》第 17 节的 key；schema 与 CI identifier linter 均拒绝 |
| 测试定义不可变 | 修改一项既有自动化断言只会新增签名 `TestDefinitionVersion`；P0 测试的 applicability 始终为 `always`，对 P0 注入 waiver 必须被拒绝，非 P0 waiver 到期后自动失效且不删除历史结果 |

此外，下列硬指标必须达到 100%：展示事实有权限化证据链接和蕴含检查、卡片有数据截止时间/水位映射/选择轨迹、状态变化为追加记录、候选恰有一个 `allocation_lane`、个人隔离不变性测试通过、时间旅行测试通过。统计模型质量指标不得在没有标注集时拍脑袋设定；影子运行期间必须建立按语言与来源类型分层的人工标注集，冻结评估方案后再确定生产阈值。

## 19. 首轮实现顺序

1. 固化规范对象链、非事件输入联合类型、条目/版本时间、ContentCursorCheckpoint 和权限化 provenance；
2. 建立 CoveragePolicyManifest.required_cells、CoverageStratumVersion、开放世界 unknown/random-exploration 路径、分层时间序列、水位映射和采集健康检查；
3. M2 按 `detector_manifest` 实现 D01–D03，交付热点、升温/衰退和可回放双时段报告；
4. M3 补齐 D04–D11；每个检测器实现独立暖机、候选和不重叠确认规则；
5. 建立命题族/候选发射幂等、候选合并、唯一 `allocation_lane`、信号版本和生命周期事件日志；
6. 实现证据/反证、蕴含兼容矩阵、来源因果主张/AI 因果推断分流、`report_claim`、双置信等级和后续观察条件；
7. 实现信号类型准入、栏目排序、覆盖轮转和盲区探索，不实现总分；
8. 冻结 AnalysisRun 的具体输出 Version ID/内容 hash 与 FeatureArtifact，分别实现确定性选择回放与档案诊断；
9. 开始 30 天影子运行和 7/30/90/180/365/730 天前瞻台账；
10. 把本规范固定夹具编译成不可变 TestDefinitionVersion，先通过 P0 门禁，再根据分层指标调整阈值和探索比例，不以提高单一命中率为目标。

本规范的判断基准不是“它是否预测了下一个热点”，而是：它是否持续把此前不显眼、但确有变化证据的世界部分带入视野，并且让每一次判断都能回到原始资料重新解释。

## 20. 无法完全消除的限制

以下限制不能通过更复杂的评分彻底解决，产品必须长期公开：

1. **世界不可穷尽**：私密交流、未数字化活动、封闭平台、审查与付费墙会形成永久盲区，“全球”只能表示已声明覆盖矩阵内的全球采样；
2. **真正黑天鹅不可预测**：系统最多发现可观察前兆，无法保证重大变化在发生前留下可采集信号；
3. **关注不等于现实**：讨论、搜索和媒体传播可能领先、滞后或完全偏离真实行动；
4. **代理变量有偏**：招聘、专利、融资、采购和政策都可能只代表意向、策略披露或制度口径；
5. **独立性无法完美识别**：匿名消息源、隐蔽所有权与线下协调可能使表面独立的来源拥有同一事实起点；
6. **操纵者会适应规则**：机器人和公关网络可以改变行为以逃避检测，风险标注只能降低误判，不能保证识别；
7. **跨语言语义不对称**：低资源语言、方言、隐喻与本地语境可能被翻译和嵌入模型错误合并或拆分；
8. **新颖性依赖档案边界**：系统未见过不等于世界未出现过，历史覆盖越短，伪新颖越多；
9. **结构变化缺少即时真值**：一条信号是否“改变世界”通常多年后仍有争议，结果标签含有人类判断和后见偏差；
10. **统计告警必然有误报**：高维、连续检测下，即使控制多重检验也会产生偶然异常；本系统选择保留部分不确定性以换取广度；
11. **模型无法可靠给出因果**：跨域共现、时间先后和扩散路径只能产生因果假设，不能自动证明因果关系；
12. **安全风险只能缓解**：提示注入、恶意附件与供应链攻击无法被一次性消除，需要持续隔离、审计与更新。

这些限制应进入日报方法说明和年度评估。系统在证据不足时必须明确说“不知道”，而不是用流畅文本掩盖不可观测部分。
