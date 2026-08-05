# 全球信息覆盖矩阵规范

| 字段 | 值 |
|---|---|
| 文档版本 | v0.1-m0-baseline |
| 状态 | M0 有条件冻结的需求基线，待 M1 feasibility 验证 |
| 更新时间 | 2026-08-05 |
| 适用范围 | 全球基础雷达的来源注册、采集、候选生成与展示覆盖 |

> 数值状态说明：本文所有经验性覆盖比例、来源数量、集中度、时延、准确率和报告门槛均为 `provisional_target`（可行性目标假设），不是已经验证的能力或最终 SLO。它们必须经过来源盘点、连接器试采、成本测量和至少一个完整基线周期的 feasibility spike 后，才能冻结为生产策略；未通过可行性验证的数字不得用于对外能力声明。法律、安全、个人数据保护及“不得泄漏个人画像/不得改变逻辑分母/时间字段必须存在”等确定性合同不变量不是经验性覆盖承诺，仍作为硬门禁执行。

## 1. 目的与结论

本规范把“全球、广泛、无个人预设地观察世界”转化为可实现、可审计的工程约束。

本系统不宣称：

- 看见了世界上发生的一切；
- 对全球人口、事件或观点做到了统计学代表；
- 实现了数学意义上的“无权重”；
- 能覆盖封闭平台、线下活动、无法联网地区或尚未留下数字痕迹的变化。

本系统能够承诺的是：

> 对一个公开定义、持续扩展、带有已知盲区的“可观察信息宇宙”进行分层扫描；用透明的最低覆盖、上限、探索配额和来源独立性规则，降低任何单一地区、语言、领域、社会角色、媒介或个人偏好垄断结果的概率。

“无权重”在产品中的准确含义是：**不使用用户画像、点击、既有观点或个人兴趣为全球基础雷达加权**。系统仍然必须使用明确、版本化且可审计的公共覆盖策略。

## 2. 范围、非目标与基本单位

### 2.1 本规范覆盖

- 可观察信息宇宙的定义；
- 来源注册与来源所有权、转载链、证据出处管理；
- 地域、语言、领域、社会角色、媒介/证据类型五个覆盖维度；
- 采集层、候选层、展示层三层不同的覆盖规则；
- 容量受限时的分层采样、最低配额与集中度上限；
- 覆盖健康、盲区、缺失和数据断流的监测；
- 反信息茧房约束；
- MVP 边界和验收标准。

### 2.2 本规范不负责

- 判断一个事件是否真实；
- 定义弱信号的特征向量、`signal_types` 判定和生命周期规则；
- 设计日报正文和对话界面；
- 根据用户投资、职业或内容兴趣定制全球基础雷达；
- 解决所有数据授权和跨境合规问题。

这些工作可以使用本规范提供的数据，但不得绕过本规范的隔离与可追溯要求。

### 2.3 基本单位

| 名称 | 定义 |
|---|---|
| 连接器 `connector` | 实现某种协议、平台或供应商访问方式的软件适配器；它是技术实现，不是覆盖或独立来源单位 |
| 来源端点 `SourceEndpoint` | 稳定 ID 为 `endpoint_id`；地址、状态和描述性 `source_declared_update_cadence` 由不可变 `SourceEndpointVersion`（`endpoint_version_id`）承载，端点不作为覆盖 SLO 的稳定分母 |
| 发布者账号 `PublisherAccount` | 稳定 ID 为 `publisher_account_id`；地区、角色、rights 等可变属性由 `PublisherAccountVersion`（`publisher_account_version_id`）承载 |
| 发布者 `publisher` | 对内容承担发布责任的组织或个人 |
| 所有权集团 `OwnerGroup` | 稳定 ID 为 `owner_group_id`；名称、控制关系和成员快照由 `OwnerGroupVersion`（`owner_group_version_id`）承载，未知时明确标记 `owner_unknown` |
| 来源注册快照 `SourceRegistrySnapshot` | 某个 as-of 可见的 endpoint/account/owner、binding、rights 与采集计划版本的物化不可变 ID 清单；必须记录 `source_registry_snapshot_id/system_available_at`，不是可重跑的动态查询 |
| 来源谱系 `SourceLineage` | 共同原始稿件、新闻稿、通讯社供稿、交叉发布或协调分发关系的稳定身份；成员快照由不可变 `SourceLineageVersion` 承载 |
| 计划采集机会 `collection_opportunity` | 主键是全局登记的 `opportunity_id`，由冻结的 `publisher_account_id × logical_stream_key × schedule_slot/cursor_range` 元组确定性派生；该元组只是 ID 派生输入，不是复合主键或新 owner/parent；漏建行仍留在分母 |
| 采集机会状态事件 `CollectionOpportunityStateEvent` | 机会错过、预注册排除或终止的 EventBase subtype；复用 EventBase.event_id，和成功 Capture 一起投影 terminal state |
| 内容游标 `ContentCursor` / `ContentCursorCheckpoint` | 稳定游标 `cursor_id` 与一次不可变检查点 `cursor_checkpoint_id`；证明某计划流处理到何处，例如序列号、更新时间边界、分页 token、日志 offset 或经验证的时间范围 |
| 采集计划清单 `CollectionPlanManifest` | 冻结唯一执行性 `planned_poll_cadence`、确定性 opportunity ID/计划机会生成规则、游标范围、权重和允许变更；降低采频或漏建机会不能回写旧分母 |
| 排名规则清单 `RankingRuleManifest` | 冻结分类型比较规则、`required_comparison_keys[]`、对应 CoverageStratumVersion IDs 和确定性 tie-break；不能为等快数据静默删慢分层 |
| 覆盖分层 `CoverageStratum` | 稳定 ID 为 `stratum_id`；地区、语言、媒介、角色和纳入谓词由不可变 `CoverageStratumVersion`（`stratum_version_id`）承载，水位、分母和历史报告必须引用当时版本 |
| 时钟源/健康快照 `ClockSource` / `ClockHealthSnapshot` | 受控时间源身份 `clock_source_id` 与一次不可变政策判断 `clock_health_snapshot_id`；保存观测、quorum、skew、TTL 和 sequence continuity，节点自报不构成证明 |
| 时钟政策清单 `ClockPolicyManifest` | 稳定 ID 为 `clock_policy_id`；冻结允许时间源、quorum、最大 skew、健康 TTL/holdover、重启/序列连续性和恢复条件，worker 不能自报可信 |
| 原始工件 `RawArtifact` | 按许可保存的原始 payload、片段、元数据或外部指针；必须使用 `storage_mode ∈ {full_bytes, licensed_excerpt, metadata_only, external_pointer}` 联合类型 |
| 物理字节对象 `StorageBlob` | 可选的内部物理存储/完整性对象；不是来源、证据或法律身份，裸内容 hash 不得成为公开 ID |
| 工件—字节绑定 `ArtifactBlobBinding` | 稳定 ID 为 `artifact_blob_binding_id`；RawArtifact 到 StorageBlob 的用途、法源、加密域、保留/撤权状态由不可变 `ArtifactBlobBindingVersion`（`artifact_blob_binding_version_id`）与 events 承载 |
| 保存清单 `PreservationManifest` | 稳定 ID 为 `preservation_manifest_id`；校验、加密、副本、保留、格式和恢复快照由不可变 `PreservationManifestVersion`（`preservation_manifest_version_id`）与 events 承载 |
| 原始条目 `RawItem` | 来源侧稳定内容身份；不承载会变化的正文、标签或状态 |
| 原始条目版本 `RawItemVersion` | 某次捕获观察到的不可变内容版本；合规删除时只能留下不含内容的受控墓碑 |
| 修订判断 `RevisionAssessment` | 对一个非初始 RawItemVersion 差异语义的稳定判断身份；不可变 `RevisionAssessmentVersion` 承载类型、reportability、决定可用时间与方法版本，重分类不得改 raw version |
| 规范条目 `CanonicalItem` | 跨来源映射后的稳定规范身份；文本、语言和去重映射由不可变 `CanonicalItemVersion` 承载 |
| 事件簇 `EventCluster` | 指向同一有边界现实事件的稳定身份；成员、边界和状态由不可变 `EventClusterVersion` 承载，且事件不能等同于一条“事实” |
| 独立证据单元 `evidence_unit` | 在观察、数据生成或一手记录上具有独立来源的证据 |
| 证据范围 `EvidenceScope` | 某段文字、表格单元、字段、测量或时间区间如何支持命题的语义范围；只服务事实门禁，不是版权/隐私许可范围 |
| 权利授权 `RightsGrant` / `RightsGrantVersion` | `rights_grant_id/rights_grant_version_id` 分别是稳定授权依据及一次不可变、可撤销的法源/用途/法域/期限决定；后续收窄或撤回新增版本/事件 |
| 获准内容范围 `AuthorizedContentScope` | `authorized_content_scope_id` 冻结某资源版本获准处理的字段、byte/span、最大展示量、处理方、transform、derivative type 与 retention；PurposeAuthorization 必须引用，EvidenceScope 不得替代 |
| 覆盖单元 `coverage_cell` | 五个覆盖维度标签的组合，用于监测稀疏交叉区域 |
| 观察窗口 `window` | 按北京时间定义的报告窗口或滚动 24 小时、7 天、30 天窗口 |
| 报告调度清单 `ReportScheduleManifest` | 稳定 ID 为 `report_schedule_manifest_id`；预先冻结时区/tzdb、recurrence、例外日、窗口/SLO 引用和确定性 slot 派生规则，不能靠漏建 slot 缩小分母 |
| 报告计划槽 `ReportScheduleSlot` | 上午/晚间名义窗口与计划发布时间的稳定调度义务；状态由 PublicationEvent/ReportSlotStateEvent 作 as-of 投影，不是可更新字段，也不因系统漏建或尝试失败而从分母消失 |
| 发布尝试 `PublicationAttempt` | 对某 schedule slot 的一次预览、构建或提交尝试；失败/预览不等于发布 |
| 发布事件 `PublicationEvent` | 某 schedule slot 首次 ReportEdition 通过 fence/CAS 与权利门禁后原子提交的唯一发布事实；每 slot 最多一个，typed API 复用 EventBase.event_id |
| 报告版次 `ReportEdition` | 某 slot 的不可变选择、顺序、水位、cutoff 与状态；文本仍是可撤销投影 |
| 报告修订 `ReportAmendment` | `report_amendment_id` 是首次版后的追加式更正、说明或内容投影变更 record；REPORT_AMENDMENT subtype 复用 EventBase.event_id，不创建第二个 initial PublicationEvent，也不改首次 SLO |
| 可报告到达 `ReportableArrival` | 初次 item、可报告 revision 或 assessment correction 的唯一逻辑到达记录；`information_arrival_id` 冻结 subject、arrival time、nominal slot 与语义版本 |
| 报告放置 `ReportItemPlacement` | 某 arrival 在 ReportEdition 中的一次不可变放置；记录 first/backfill 关系，并对每个 information_arrival 的 first placement 作唯一约束 |
| 卡片放置 `ReportCardPlacement` | selected CandidateSelectionUnit 在 Publication/ReportAmendment 中的不可变卡片位置；绑定 candidate、surface、card order 与渲染 SignalVersion，不借用原始资讯首发语义 |
| 主张生成义务 `ClaimGenerationUnit/Decision` | 按 presentation context、typed container 与 claim slot 确定性物化；每个 required slot 有唯一 terminal decision，缺行、空集合或 failed 不能发布 |
| 主张表达/引用 `ClaimExpressionVariant/ClaimCitation` | 每 locale/channel/variant role 的语义等价表达，以及 claim 与 exact source title/quote/scope/rights/citation role 的关系 |
| 原始资料列示 `RawSourceListingReference` | 无 claim 的原始资料列表中，ReportItemPlacement 与 exact source metadata/title/rights/hash 的关系；不能使用 evidence/support 标签 |
| 呈现计划 `PresentationRenderPlan/PresentationContentUnit` | 每 event 唯一 plan；枚举标题、正文、caption、tooltip、alt/ARIA、通知和导出的 kind-specific typed child；最终输出双向相等 |
| 累计呈现快照 `ComposedPresentationSnapshot` | initial publication 或 amendment head 后的完整 placements/claims/variants/citations/content units/render hash；当前读取不拼 delta |
| 服务 SLO 快照 `ServiceSLOSnapshot` | 以冻结 schedule-slot 分母计算的 standalone immutable record；自身 ID 为 `service_slo_snapshot_id`，只决定服务声明，不改写单期 edition，也没有稳定 snapshot parent |
| 雷达表面/流水线 `RadarSurface/RadarPipelineManifest` | 跨刷新稳定的公共表面及其 scope/method epoch、required stages、选择、claim/render 与 current-head 支配规则 |
| 全球雷达快照 `GlobalRadarSnapshot` | `global_radar_snapshot_id` 是某次公共域候选、特征、选择、水位、卡片、claims 与 render plan 的 standalone snapshot；不得含用户、当前问题、点击、记忆或个人 embedding |
| 雷达发布/卡片 `RadarPublicationEvent/RadarCardPlacement` | RADAR_PUBLICATION 以 surface expected-head CAS 原子切换完整 snapshot；卡片只属于该 presentation event，不与日报 placement 混用 |

覆盖配额默认按**事件簇**计数，而不是文章数；来源多样性按**来源谱系/所有权集团**计数，而不是域名数。这样可以避免同一通讯社稿件被转载 100 次后被误认为 100 个独立信号。

采集健康的默认计数单位是计划采集机会及其游标完整性，不是端点数量。端点拆成十个、十个端点合成一个或连接器实现被替换时，只要逻辑账号、流、计划时段和游标范围不变，覆盖分母与历史时间序列必须保持不变。端点、账号、发布者、所有权集团和来源谱系之间的映射均需版本化。

### 2.4 稳定身份、版本与事件闭合

名称后缀不决定 schema。每个对象必须引用 05 第 5.1 节记录原型注册表中的明确 archetype：`stable_identity` 只承载跨时间身份；`immutable_record` 只有自己的 record ID，只有对象表明确声明时才引用 parent；`immutable_manifest` 的 manifest/version ID 本身就是配置身份；`event_subtype` 复用 `EventBase.event_id` 作为 PK/FK。`SupersessionEvent`、`DeletionEvent`、`PublicationEvent`、`ExternalPointerCheckEvent` 等 typed API 名不得拥有脱离 EventBase 的第二个事件 ID。

不得用 `*Version/*Snapshot` 通配规则发明稳定 parent、完整双时间或闭合字段。只有 05 第 5.1 节 time-profile registry 登记为 `bitemporal_version_time` 的对象使用第 7.2 节双时间字段与事件投影的 `projected_valid_to/projected_system_to`；`RawItemVersion` 使用 observe/capture/available times；`derived_record_time`、`operational_record_time` 和 standalone snapshot 分别使用 registry 指定的字段，不自动拥有 `system_from/valid_from`。standalone snapshot 只有自身 snapshot ID、`snapshot_frozen_at/system_available_at/as_of` 和物化成员，不存在虚构的 registry parent ID、stable parent 或 valid/system closure。记录和 manifest 均不可原地覆盖，但“不可变”本身不推出双时间。

仅 bitemporal version 的取代、合并、拆分、撤销和生命周期关闭通过 EventBase/SupersessionEvent 形成 projected ends；snapshot 被新 snapshot 替代时只由引用方选择新 ID。删除由 EventBase/DeletionEvent 驱动内容投影撤销，不得借“不可变”保留已失去处理依据的正文。为性能维护的投影索引可以重建，但不是权威历史。

## 3. 可观察信息宇宙

### 3.1 目标采集宇宙、可采集宇宙与完成状态

在 `coverage_policy_version`、`collection_plan_id + collection_plan_manifest_hash`、窗口 `W` 和时间点 `t` 下：

```text
U(W) = 策略希望观察、并由冻结 CollectionPlanManifest 为 W 确定性推导的 collection_opportunity 集合；
       受限、失联、尚未接入但仍属于目标边界的逻辑流继续留在 U

O_acquire(W,t) = U 中在该机会发生时具有有效处理依据、且已有配置访问路径的机会；
                 单次超时、限流或临时断流仍属于 O_acquire

C_acquire(W) = O_acquire 中已成功覆盖预期逻辑范围，或以完整游标/代理证明确认该范围无新版本，
               并写入响应状态、捕获清单和游标证据的机会；部分分页、超时和失败不属于 C_acquire
```

每个机会应预先登记 `opportunity_id`、`publisher_account_id`、plan 内的 `logical_stream_key`、`collection_plan_id`、计划时段或目标游标范围、`opportunity_weight` 和预期结束边界；但分母不得依赖机会行是否成功写出。`logical_stream_key` 是 CollectionPlanManifest 内的不可变值，不冒充独立实体 FK；`opportunity_id` 必须由冻结 plan 的账号/流/slot 或 cursor range 规则确定性推导。独立对账作业以 manifest 展开结果与物化机会表核对；若采集调度器整窗宕机导致机会行从未创建，对账仍补建该义务、追加 CollectionOpportunityStateEvent、记录 `COLLECTION_OPPORTUNITY_MISSED` 并计入 U/O_acquire 的适用分母，不能通过缺行美化完成率。`opportunity_weight` 的定义必须随 `CollectionPlanManifest` 公开，不能由实际抓取结果反向修改。

`SourceEndpointVersion.source_declared_update_cadence` 只描述来源自报或观察到的更新节奏，不产生执行义务，也不能直接改变任何完成率分母。`CollectionPlanManifest.planned_poll_cadence` 是唯一执行性 cadence；清单至少冻结来源描述 cadence 的证据、执行 cadence、二者差异依据、时区、确定性 opportunity ID 与 schedule/cursor 规则、计划权重、允许跳过条件、生效区间、版本/hash 和变更依据。二者偏离必须审计并做成本/覆盖敏感性报告。月更来源在 manifest 没有计划任务的小时不进入该小时机会分母；到了 manifest 规定的计划周期却未执行或漏建机会行，必须记录 `COLLECTION_OPPORTUNITY_MISSED`。

降低抓取频率、合并 schedule slots、缩短目标游标范围或把困难来源改成“按需采集”，都必须生成新的 `CollectionPlanManifest` 和 change event。旧计划 cohort 的机会、权重、schedule adherence 和完成率不可回写；新旧计划至少双跑或做缺失/成本敏感性分析，并在健康报告中并列展示。系统不得仅靠减少计划机会让 `opportunity_completion`、`cursor_completeness` 或水位滞后看起来改善。

采集 SLO 使用以下口径，而不是端点数量：

```text
acquire_observability = Σ weight(O_acquire) / Σ weight(U)

opportunity_completion = Σ weight(C_acquire) / Σ weight(O_acquire)

cursor_completeness = Σ weight × covered_cursor_fraction / Σ weight(O_acquire)
```

`covered_cursor_fraction` 表示计划游标范围中有完成证据的比例。正常轮询且游标完整、但发布者没有新内容的机会仍计入 `C_acquire`；只返回首页、分页中断、序列号断档或时间范围有洞时不进入 `C_acquire`，且不能计为游标完整。所有尝试及失败都另存 attempt audit，不能因“任务已运行”冒充机会完成。没有可靠游标的来源必须使用显式的完整性代理和 `cursor_evidence_quality`，不能默认 100%。

来源受限、失联或授权终止时仍留在 `U` 并形成覆盖债务，不能通过移出分母让指标虚假改善。只有经版本化策略审查确认不再属于目标边界，逻辑流才能退出 `U`；退出历史不可删除。端点拆分、合并、换域名或更换 connector 只更新机会到物理访问路径的映射，不产生新的覆盖单位。

发布者账号、所有权集团、来源谱系和事件簇分别使用来源可达性、集中度与多样性指标；它们不得和采集机会 SLO 混成一个比率。

### 3.2 按处理目的区分可观察范围

“可以访问”不能自动推出“可以解析、送入模型、生成信号、展示或估算流行度”。每项 allow 必须落到具体 `artifact_id`、`item_version_id` 或其他已定义 record ID、一个有效 `RightsGrantVersion` 和至少一个 `AuthorizedContentScope`，并记录 `rights_snapshot_id`、法域、处理依据、隐私等级与 revocation epoch。许可字段/span、最大展示量、处理方、用途、transform/derivative、retention 等边界只由 AuthorizedContentScope 表达；EvidenceScope 只说明“哪段支持哪个命题”，不能形成或扩大处理许可。

AuthorizedContentScope 必须以 `rights_grant_version_id` 和 `(resource_record_identity_id, resource_record_type)` 绑定同一个确切资源 record，不得只绑裸 stable identity。数据库对 `(authorized_content_scope_id, rights_grant_version_id, resource_record_identity_id, resource_record_type)` 建唯一约束；`PurposeAuthorization.decision=allow` 必须用同一四元组复合 FK 回指该 scope/grant/resource，禁止把 Grant A 与 Scope B 拼成 allow。deny 可不引用 grant/scope，但必须保存 reason；一个操作需要多个 scopes 时逐项引用并全部通过，不得把范围隐式 union。

系统至少维护以下相互独立的用途集合：

| 集合 | 对象域 | 含义 |
|---|---|---|
| `O_acquire` | 计划采集机会 | 可依法并通过已配置路径执行采集 |
| `O_extract` | 原始 artifact version | 可进行正文/媒体解析并保存相应派生物 |
| `O_model.local` | artifact/derived version | 可在隔离的本地模型环境中处理 |
| `O_model.provider[provider_id]` | artifact/derived version | 可发送给指定外部模型供应商；不同 provider 必须分别决策 |
| `O_train[model_id,purpose]` | artifact/derived version | 明确允许进入指定模型和目的的 training/fine-tuning 数据；默认 false，推理许可、公开可访问或保存许可均不能推出训练许可 |
| `O_signal` | artifact/derived version | 可用于生成观察、趋势或弱信号；许可撤回后可被失效化 |
| `O_display` | artifact/derived version | 可向用户展示；必须细分元数据、短引文、全文和媒体权限 |
| `O_prevalence` | 传播观察记录 | 采集过程、纳入概率、游标和比较分母足以用于流行度/传播规模测量 |

这些集合是“当前存在有效 grant/scope”的索引投影，不是无限允许的布尔授权，也不存在默认包含关系。例如，R2 内容可能允许采集元数据和显示链接，却不允许保存全文或发送给外部模型；某版本也可能允许本地抽取但禁止用于信号。允许外部 provider 做一次推理不等于允许 provider 或本系统保留样本训练，所有 training/fine-tuning 资格默认 false，必须对 `model_id + purpose` 单独明确授权。内部全文建模和“最多展示 200 字”必须是不同 purpose/scope；`O_display` 不能绕过 max bytes/characters，`O_prevalence` 除权利外还要求测量口径可比较。

`O_extract/O_model/O_train/O_signal/O_display/O_prevalence` 的分母是已捕获的 artifact versions 或传播观察记录，必须分别按条目、事件、来源谱系及适用字节量报告；不得拿它们直接除以机会集合 `U`。权利变更产生新快照，并可撤销后续用途资格，不能静默改写历史决策。

权限不是一次性入口检查。采集、抽取、模型出站、训练集构建、training/fine-tuning、派生持久化、候选选择、报告/实时雷达渲染发布和用户检索都必须按当时最新 policy 与 rights snapshot 重新授权，并保存 `purpose_authorization_id`、typed `resource_record_identity_id/resource_record_type`、`rights_grant_version_id`、`authorized_content_scope_id`、资源 record hash、目标处理方、`checked_at`、`expires_at` 和 `revocation_epoch`。allow 必须通过上述同 grant/scope/resource 复合 FK；每次显示/导出还要原子核对实际 byte/character/span/transform 不超过 scope。删除或撤权提高 epoch 后，仍使用旧 epoch 的在途任务必须被取消或标记 tainted；其输出不得持久化、参与信号或进入展示。首次报告发布必须在写入唯一 PublicationEvent 的同一原子提交中复核当前 epoch，实时雷达也必须在 RADAR_PUBLICATION 与首字节前 view-token 校验中复核；竞争条件使用 `REVOCATION_RACE_BLOCKED` 阻断。旧 epoch 雷达 head 整体转为 recomputing/unavailable，不能保留旧排序再逐卡红删；读时内容投影和缓存键均不得绕过 epoch/head token。

若外部模型请求已经发送后才发生撤权，系统不能声称此前传输已被撤销；必须阻断后续持久化和展示、执行供应商删除/不保留流程，并记录不可逆暴露范围。

### 3.3 宇宙边界必须显式暴露

每份日报和雷达快照至少显示：

- 策略版本、采集计划版本、来源注册表快照 ID 和 rights snapshot；
- 当前支持的地区、原文语言和媒介类型；
- 本窗口计划机会、可采集机会、完成机会、游标空洞，以及活跃、降级、断流、受限、退出的逻辑来源数量；
- 当前已知的主要盲区；
- `acquire_observability`、`opportunity_completion`、`cursor_completeness`，各用途集合的资格比例，以及因授权、登录墙、网络中断、游标空洞或解析失败形成的覆盖债务；
- endpoint/connector 映射变更及其“不改变逻辑分母”的验证结果；
- 内容窗口和实际抓取窗口。

### 3.4 先天不可消除的盲区

以下对象不能被“更多抓取”自动解决，必须在输出中常驻提示：

- 低联网率、冲突、审查或基础设施薄弱地区；
- 不使用 MVP 支持语言的本地信息；
- 私密群聊、闭门会议、企业内部信息和非公开政府活动；
- 口头传播、社区生活、线下交易和未数字化资料；
- 需要当地语境才能识别的讽刺、暗语、方言和文化信号；
- 付费墙、登录墙、反爬限制或许可禁止保存的内容；
- 有意沉默、害怕发声或没有传播能力的人群。

“没有观察到讨论”不能直接解释为“没有发生变化”。

## 4. 三层覆盖模型

覆盖不能只在最终日报里检查。必须分别约束采集、候选生成和展示，否则上游偏差会被下游看似多样的排版掩盖。

| 层级 | 目标 | 默认计数单位 | 主要约束 |
|---|---|---|---|
| L1 采集层 | 让不同逻辑来源有稳定进入档案的机会 | 计划采集机会、内容游标、发布者账号 | 机会完成率、游标完整性、地区/语言/类型最低谱系数、断流告警 |
| L2 候选层 | 让不同事件有被分析的机会 | 事件簇、来源谱系 | 覆盖保底、集中度上限、探索抽样、去重、独立性 |
| L3 展示层 | 让用户看见热点、变化和陌生领域 | 展示卡片/事件簇 | 最低多样性、热点与探索分栏、透明选择理由 |

三层指标不得相互替代。例如，采集了大量阿拉伯语原文，但候选层全部过滤掉，语言覆盖仍然判定失败。

本规范后文的“计划机会/游标完整性/独立谱系最低数”属于 L1；“滚动 7 天事件簇占比上下限”同时适用于 L2、L3 的**探索视图正常预算**；它们都不适用于流行度视图的分布估计、局部快讯或重大事件溢出区。L3 的热点/流行度栏如实展示观测分布，探索栏才执行覆盖配额。任何仪表盘必须标清层级、用途集合和视图，不能用 L1 达标替代 L2/L3，也不能用探索配额修饰流行度。

## 5. 覆盖维度与分类规则

五维笛卡尔积会产生大量空格，MVP 不为每个组合强设配额。实现采用：

1. 对每个单维设置最低覆盖和集中度上限；
2. 对高风险交叉格设置重点监测清单；
3. 用“覆盖债务”发现持续为空的格子；
4. 只有具备足够候选且满足最低来源质量时才填充，绝不使用垃圾内容凑配额。

每条内容在每个维度有一个 `primary_label`、零到多个 `secondary_labels` 和一个置信度。只有主标签计入硬配额，辅助标签用于检索和交叉分析，防止一条内容重复占满多个配额。无法可靠判断时使用 `unknown`，不得强制猜测。`domain=unknown` 或 `role=unknown` 不是质量失败：候选仍按与已分类内容相同的权利、安全、provenance、去重、独立性和最低内容质量门槛判断 `unclassified_eligibility`，不能在进入探索抽样前因“无法塞进现有 taxonomy”被静默丢弃。unknown 也不自动代表新颖或重要，必须经过第 8.3 节的预注册随机子分层而非人工挑选。

本节所有百分比、来源数和触达数都是 feasibility spike 前的 `provisional_target`。其中事件占比的下限和上限只约束 `exploration_lens.normal_budget`：不改变原始档案，不改变 `prevalence_lens` 的传播规模，不限制有独立标识的局部快讯，也不限制第 8.6 节重大事件溢出区。L1 的谱系最低数按“至少一个 publisher account 对应当前 `O_acquire` 中计划机会”的可观察谱系统计，不按 endpoint 数统计。

### 5.1 地域维度

地域描述事件主要发生地，而不是服务器位置或媒体总部。另存发布地、涉及地和影响地。

MVP 使用 10 个互斥宏观区域和一个跨区域类别：

1. 撒哈拉以南非洲；
2. 中东与北非；
3. 欧洲；
4. 北美；
5. 拉丁美洲与加勒比；
6. 东亚；
7. 南亚；
8. 中亚；
9. 东南亚；
10. 大洋洲与太平洋岛国；
11. 全球/跨区域。

国家和地区使用版本化的 ISO 映射表；争议地区保留原来源称谓和系统规范码，不通过覆盖系统做政治立场判断。

MVP 建议约束：

- 滚动 7 天内，每个宏观区域的事件簇占比下限为 4%；
- “全球/跨区域”下限为 5%；
- 任一宏观区域占比上限为 25%；
- “全球/跨区域”占比上限为 15%，不能成为难以分类内容的倾倒区；
- 滚动 30 天内至少触达 60 个国家或地区；
- 每个宏观区域至少维护 10 个映射到 `O_acquire` 计划机会的可观察独立来源谱系，其中至少 4 个为当地发布者；
- 地区来源不足时记录覆盖债务，不从其他地区自动借量并伪装达标。

“触达一个国家或地区”要求 30 天内至少存在 2 个独立来源谱系的合格事件簇，且其中至少 1 个来自当地发布者；只有媒体总部提及该地不算有效触达。宏观区域映射表必须互斥、版本化；多地事件使用主要发生地为主标签，并把其他地点记为辅助标签。

国家级覆盖采用轮转而非静态“重要国家榜”。轮转优先级由覆盖债务、来源健康、人口可见性、跨境影响、突发风险和历史低覆盖共同决定；不得使用用户兴趣。

### 5.2 语言维度

语言按**原文语言**计数。翻译文本不能替代原文语言覆盖，英语媒体对非英语地区的报道也不能计入当地语言覆盖。

MVP 正式支持：中文、英语、西班牙语、阿拉伯语、法语、俄语、葡萄牙语、印地语、日语、韩语；同时为印度尼西亚语和斯瓦希里语建立不计入正式达标率的试验采集与评测路径。该集合是由覆盖人口、地区缺口、可取得来源和当前 NLP 能力共同形成的首版工程边界，不代表这些语言更重要。选择依据及未支持语言清单必须公开。

MVP 建议约束：

- 滚动 7 天内，每种正式支持语言的事件簇占比下限为 3%；
- 英语占比上限为 35%；
- 任意两种语言合计上限为 55%；
- 每种正式支持语言至少维护 6 个映射到 `O_acquire` 计划机会的可观察独立来源谱系；
- 原文、标准化文本、译文分别保存并关联，不覆盖彼此；
- 语言识别置信度低于阈值时进入人工抽检队列，标为 `unknown` 而不是默认英语；
- 每种正式支持语言建立独立评测集，评估分句、实体、数字、否定、引语归属和翻译保真度；不能用英语测试结果替代其他语言结果。

扩展语言按“人口与地区盲区 + 当前覆盖债务 + 可获取本地来源 + 解析能力”排队，不能根据用户点击热度排序。优先候选包括但不限于孟加拉语、乌尔都语、印度尼西亚语、土耳其语、波斯语、德语、意大利语、越南语、泰语、斯瓦希里语及其他非洲本地语言。

### 5.3 领域维度

领域顶层分类保持稳定，具体趋势使用动态主题簇。这样既允许 AI 发现新概念，又能长期测量某个大类是否被挤出。

MVP 顶层领域：

1. 治理、法律与公共政策；
2. 地缘政治、安全与冲突；
3. 宏观经济、贸易与金融；
4. 企业、产业与供应链；
5. 计算、通信、AI 与半导体；
6. 物理科学、材料与航天；
7. 生物、医疗与公共卫生；
8. 能源、气候与环境；
9. 农业、食品与水；
10. 基础设施、交通与城市系统；
11. 人口、迁移、劳动与社会保障；
12. 教育、知识生产与科研制度；
13. 文化、媒体、宗教与价值观；
14. 公民社会、权利、治理失灵与犯罪。

MVP 建议约束：

- 滚动 7 天内，每个顶层领域事件簇占比下限为 2%；
- 任一领域占比上限为 18%；
- 每个领域至少维护 6 个映射到 `O_acquire` 计划机会的可观察独立来源谱系，其中至少 2 个不是综合新闻媒体；
- 新动态主题首先作为子主题存在，不因近期热度立即改写顶层分类；
- 顶层分类变更需版本化，并提供新旧映射以保持时间序列可比性。

### 5.4 社会角色维度

系统同时记录“发布者角色”和“事件中发声/行动者角色”，两者不能混淆。配额按事件中主要证据或观点的来源角色统计。

MVP 角色：

1. 政府、监管与国际组织；
2. 科研、教育与专业机构；
3. 企业、创业者与行业组织；
4. 投资者、金融机构与市场参与者；
5. 劳动者、专业从业者与工会；
6. NGO、公民社会、倡议与监督组织；
7. 地方社区、边缘群体与现场见证者；
8. 在公开数字渠道中可观察到的公众、创作者与网络社群。

MVP 建议约束：

- 滚动 7 天内，每类角色占比下限为 3%；
- 政府与企业两类合计占比上限为 45%；
- 公众/社交内容必须经过操纵风险检测，但不能因此被整体排除；
- 当一个事件只有强势机构发声时，明确显示“缺少受影响群体/独立观察者视角”；
- 角色未知率单独报告，不能自动归为“公众”。该类别只能描述留下公开数字痕迹的人，不能外推为全体民意。

### 5.5 媒介与证据类型维度

媒介类型描述信息如何产生，不等于真实性等级。官方公告可能准确记录“官方说了什么”，但不自动证明公告中的事实。

MVP 类型：

1. 法律、政策、政府公告与官方统计；
2. 公司公告、财报、监管披露与采购；
3. 论文、预印本、数据集与科研记录；
4. 专利、标准、代码仓库与技术文档；
5. 招聘、产品、价格、交易、物流等行为数据；
6. 通讯社、调查报道与综合新闻；
7. 地方媒体、行业媒体与专业通讯；
8. 社交媒体、论坛、社区与一手见证；
9. 音频、视频、演讲及其文字稿。

MVP 建议约束：

- 滚动 7 天内，每种已支持类型占比下限为 2%；
- 综合新闻类占比上限为 40%；
- 每个变化候选尽量同时连接“叙事证据”和“现实行动证据”；
- 暂不支持的媒介必须在覆盖边界中列出，不能被静默忽略。

## 6. 来源注册、所有权与独立性

### 6.1 来源注册表必填字段

来源注册表必须是规范化、版本化的关系图，而不是把一个 `endpoint_id` 和一个 publisher account 压在同一条不可拆行中。`publisher_account + logical_stream_key` 是计划身份；endpoint/account 多对多映射作为 `SourceRegistrySnapshot` 的物化关系元组，引用当时可见的 `endpoint_version_id/publisher_account_version_id` 及关系依据。SourceRegistrySnapshot 是 standalone snapshot：关系变化创建新版本记录和新 snapshot，由引用方选择新 ID；不得另造未在 05 registry 登记的 EndpointBinding/endpoint_mapping Version、stable parent 或 supersession closure。

`SourceEndpoint`、`PublisherAccount` 和 `OwnerGroup` 的稳定身份行不得直接保存可变地区、publisher role、所有权成员、rights、endpoint 地址或 `source_declared_update_cadence`。这些属性分别进入 `SourceEndpointVersion`、`PublisherAccountVersion`、`OwnerGroupVersion`；执行性 `planned_poll_cadence` 只属于 `CollectionPlanManifest`。每次报告与回放冻结 `SourceRegistrySnapshot`，将当时可见的 endpoint/account/owner/binding/rights/collection-plan version IDs 与 snapshot `system_available_at` 物化为不可变 ID 清单，不允许保存一个日后可重跑的动态查询。2027 年才观察到的收购、角色重分类或 cadence/rights 变化不能回写 2026 年的所有权集中度、独立性、社会角色或机会计划；retrospective reanalysis 可以另算，但必须标明使用新知识，不能冒充 2026 as-known。

下面是跨注册实体必须具备的概念字段，不表示它们都位于同一张表：

```text
connector_id
endpoint_id
endpoint_version_id
publisher_account_id
publisher_account_version_id
owner_group_id | owner_unknown
owner_group_version_id
source_registry_snapshot_id
logical_stream_key
collection_plan_id
collection_plan_manifest_hash
content_cursor_type
system_available_at
country_or_region
original_languages[]
publisher_role
media_types[]
domains[]
access_method
source_default_license_hint
source_default_privacy_hint
rights_resolution_method
rights_grant_version_ids[]
authorized_content_scope_ids[]
source_declared_update_cadence  # SourceEndpointVersion 描述字段
planned_poll_cadence            # CollectionPlanManifest 唯一执行字段
cadence_evidence[]
collection_priority_class
registered_at
last_completed_opportunity_at
health_state
editorial_or_generation_method
known_syndication_partners[]
political_or_commercial_affiliation_if_known
registry_evidence_urls[]
registry_version
```

来源级许可和隐私字段只能作为发现阶段提示，最终用途资格必须按第 3.2 节落到 artifact version。未知所有权、资助关系或转载关系必须使用明确状态，不得用空值表示“没有关系”。`owner_unknown` 不能作为“所有权相互独立”的证据；未知来源需单列集中度，发现共同基础设施、人员、稿件或分发行为时保守归组。

不得给媒体品牌、发布者账号或个人设置永久、全局的“真相分”或“可靠性总分”。可以保存有证据和有效期的历史更正、方法透明度、利益冲突、已知自动生成方式等来源上下文，但事实支持强度必须针对具体主张、具体版本和具体证据评估，不能由品牌分数代替。

### 6.2 来源独立性分层

| 级别 | 情况 | 在独立证据计数中的处理 |
|---|---|---|
| I0 | 完全镜像、重复 URL、同账号交叉发布 | 合并为 1 条 |
| I1 | 同一通讯社稿、新闻稿、原帖或逐字改写 | 同一来源谱系，只计 1 |
| I2 | 同一所有权集团下的不同媒体独立撰写 | 来源可分开，所有权集中度只计 1 个集团 |
| I3 | 不同发布者报道，但共同依赖同一份文件/同一位消息人士 | 可算叙事扩散，不算独立事实证据 |
| I4 | 不同主体产生的独立数据、观察或一手记录 | 独立证据单元 |
| `dependency_unknown` | 无法确定是否共同依赖匿名消息源、隐藏所有权、线下协调或未知原稿 | 不进入保守独立下界；进入可能独立上界并显式显示未知量 |

系统必须维护内容指纹、引用链、超链接、发布时间、共同实体/引语及所有权关系构成的 provenance 图。自动判断不确定时保守合并并标注待审。

每个事件或信号至少输出：

```text
independence_lower_bound = 仅计已确认具有独立数据生成/观察起点的证据单元
independence_upper_bound = lower_bound + dependency_unknown 中仍可能独立的起点
dependency_unknown_count
dependency_unknown_share
```

不得把上界写成“已有 N 份独立证据”。弱信号或事实确认可以使用更严格的独立性门槛；覆盖统计至少按事件簇、来源谱系和所有权集团三个口径同时显示。

所有权集团、publisher role、地区和来源描述 cadence 必须从该 edition 冻结的 `SourceRegistrySnapshot` 读取；执行 cadence 必须从同时冻结的 `CollectionPlanManifest.planned_poll_cadence` 读取。后见的收购、重分类或 cadence 变化只追加新版本/manifest；除明确的 retrospective reanalysis 外，不得以当前注册表重算旧 edition 并覆盖当时的独立性、角色分布或机会分母。

### 6.3 集中度约束

- 单一来源谱系在滚动 7 天探索正常预算候选层占比不得超过 5%；
- 单一所有权集团在探索正常预算中不得超过 10%；
- 探索正常预算前 10 大来源谱系合计不得超过 35%；
- 同一事件的 100 篇转载只形成 1 个来源谱系，但保留传播规模指标；
- 转载规模可用于衡量“传播”，不可用于证明“独立发生”或“事实更可信”。

### 6.4 来源准入与发现偏差

进入目标采集计划 `U` 不要求来源观点“正确”或符合主流，但至少要求：逻辑账号与流可登记、访问路径及处理依据可审计、时间可追溯。纯镜像端点可以作为同一传播谱系的访问路径，但不能制造新覆盖单位。可疑、宣传或低可靠内容可以作为“某种叙事正在传播”的观察对象，但必须保留风险标签，不能用来填补独立事实证据配额。

来源发现本身也会产生隐含权重，因此：

- 不依赖单一搜索引擎、聚合器、通讯社或社交平台生成来源注册表；
- 任一上游发现/分发服务提供的候选事件不得超过候选层 30%；
- 同时使用官方目录、学术/行业名录、当地媒体清单、开放数据目录、已知链接网络和分层随机发现；
- 每月从低覆盖地区、语言和角色中主动寻找新来源，优先级由覆盖债务决定；
- 来源退出、无法访问和被平台降权的历史均保留，不能只研究“幸存来源”；
- 对外部搜索排名只能视为一个带偏差的输入特征，不能直接当作全球热度。

来源发现不能只闭合“已经选择运行的 frame”。每个声称覆盖的周期必须在读取任何目录/query 结果前激活 `SourceDiscoveryProgramManifest`，冻结地区×语言×渠道分层、目录/query 模板、运行频率、随机种子、纳入概率和确定性 frame-opportunity ID。每个预期批次先物化唯一 `SourceDiscoveryFrameOpportunity`，再写唯一 `SourceDiscoveryFrameDecision(run|skipped|failed)`；`run` 必须一对一引用一个 `SourceDiscoveryFrameManifest`。`program frame opportunities = run manifests ∪ skipped/failed terminals` 是上一层硬门禁：只为容易、准入率高或已有覆盖的格创建 frame，即使已建 frame 内部完全闭合，也会形成 program discovery gap，并阻断跨格“来源发现覆盖/多样性已达标”声明。

frame 内的来源分母同样不能由最终准入来源反推。每次版本化目录、搜索 query、链接遍历或分层随机发现批次必须先冻结 `SourceDiscoveryFrameManifest`，保存渠道/查询、目录或分页快照与 inclusion receipt、分层、publisher/account/logical-stream 去重规则和确定性 opportunity ID。frame 展开的每个规范来源候选都物化唯一 `SourceDiscoveryOpportunity` 与一个 terminal `SourceDiscoveryDecision(admit|reject|duplicate|failed)`；`frame opportunities = terminal decisions`，未准入 U 的候选和原因也留在分母。只为容易接入或最终进入 U 的来源建决定、漏掉目录分页或删除 rejected/failed 行时形成 discovery gap，并阻断单 frame 准入率/完整性声明。

每个新增来源/端点必须有不可变 `SourceDiscoveryDecision` 与 `RecruitmentCohort`，冻结发现原因、公共证据、规则以及 candidate/query causal parents。每次运行物化 `ConditioningAncestryClosure`，覆盖触发 candidate/family/query、cohort、source versions、CoverageItems 和所有后继 candidate/family；条件化来源不得为闭包内任何后继提供确认、跨圈扩散或流行度，只比较 candidate ID 不同不能洗白。只有闭包外的预冻结随机/留出框、无关覆盖债务招募或预注册独立性 oracle 可以。

## 7. 版权、隐私、安全与删除

“原始信息永久保存”是产品愿景，不是对所有资料都合法可行的绝对承诺。每个 `artifact_id`、`item_version_id` 或其他已定义对象的版本 ID 必须独立分级；同一来源的不同帖子、附件、修订版或数据字段可以有不同权利：

| 等级 | 可保存内容 | 默认处理 |
|---|---|---|
| R0 | 明确允许长期保存/公有领域/用户自有 | 保存完整原文和历史快照 |
| R1 | 允许内部检索但限制再分发 | 加密保存全文，仅内部检索；展示受限 |
| R2 | 只允许合理引用或缓存 | 保存元数据、内容指纹、AuthorizedContentScope 许可片段和原链接 |
| R3 | 禁止保存或访问授权失效 | 仅保存合规审计记录，正文不入库或及时删除 |

版权许可 `license_class` 与隐私敏感度 `privacy_class` 是两个独立维度。每个版本同时记录第 3.2 节的用途资格。公开可访问不等于可以永久保存、对外展示、建立人物画像、传输给外部模型或用于 training/fine-tuning。社交、论坛、社区和一手见证内容至少额外记录：是否包含个人信息/敏感个人信息、处理依据、数据主体所在法域、保留期限、展示范围、是否允许发送给本地模型及每一个外部模型供应商、每个 `O_train[model_id,purpose]` 决策，以及去标识化状态。

建议隐私等级：

| 等级 | 示例 | 默认处理 |
|---|---|---|
| P0 | 不含可识别个人信息的机构资料 | 按版权等级处理 |
| P1 | 公开职业身份、公开署名观点 | 最小化保存；展示仍遵守来源语境和许可 |
| P2 | 可识别普通个人、位置、联系方式或组合后可识别信息 | 默认去标识化，限制检索和外部模型传输，设置短保留期 |
| P3 | 健康、生物识别、未成年人、精确位置、私密关系、受迫害风险等高敏感数据 | 默认不入通用档案；确有必要时需专项依据、隔离存储和审批 |

原始附件、压缩包、文档宏、脚本和媒体文件一律视为不可信输入：在隔离环境中做类型识别、恶意内容扫描和安全转码；不得执行脚本、宏、嵌入对象或来源提供的提示指令。未通过检查的附件只保留允许的哈希与隔离记录，不进入解析或模型管线。

外部模型调用必须引用冻结 `ModelTaskManifest`，由唯一 egress proxy 把实际出站每个 fragment 与 `OutboundPayloadManifest` 逐字节对账。provider thread/file/vector-store/cache/batch handle 必须引用递归物化有效输入、权利与撤权依赖的 ProviderContextSnapshot；公共调用的 transitive private-lineage=0。callback 用 provider key/version 对 job+invocation+body+nonce+scope/owner+全部撤权域签名，单 invocation 只接受一个 terminal output。网页/provider 输出均 tainted；manifest-required ModelOutputValidationUnit 各有唯一 Decision，全部通过后 typed field 才能下游使用。派生文本或 remote handle 不能洗白 R1/P2/P3/personal lineage，单一 epoch 也不能代替完整 RevocationDependencySnapshot。

采集器只允许经过策略批准的网络协议和目的地；每次重定向都重新校验，阻止私网、环回、云元数据端点和本地文件访问，并设置响应大小、递归解压、媒体时长和解析资源上限。原始 HTML 在界面中必须以惰性文本或经过净化的隔离视图呈现，不能执行来源脚本、事件处理器或主动嵌入内容。

必须实现级联删除：接到有效版权删除、数据主体删除/撤回请求、授权终止、处理依据失效或来源策略变化后，从原文对象、搜索索引、向量索引、缓存、衍生训练集、人物/实体关系和可识别摘录中删除或失效化。训练集 snapshot 必须能从 artifact/version 反查 membership、authorization epoch、model/checkpoint 和 purpose。若删除义务适用于已训练 checkpoint，而模型不能完成可验证样本级 unlearning，则必须禁用并销毁受影响 checkpoint、从清洁 snapshot 重训；做不到这一点的模型不得接收可能产生该删除义务的内容。外部推理 provider 的不保留/不训练约束也必须独立配置，不能沿用推理许可。

删除可以保留法律允许且不含原文、短引文、个人信息或可逆内容指纹的最小非内容审计事件，例如请求类别、接收/完成时间、影响系统、作业状态和失败重试记录。旧 edition 还可保留项目 ID、原顺序、删除原因与时间，以及不含内容的随机 receipt 或受控 HMAC；低熵短句、电话号码、标题等不得留下可被字典枚举的裸 hash，HMAC 密钥也不得暴露给普通查询或客户端。审计记录的目的只能是证明删除流程执行，不能成为绕过删除继续还原内容的影子档案。

所有摘要、观察、实体关系、信号和报告卡片都视为由证据生成的**可撤销投影**。底层版本失去 `O_signal` 或 `O_display` 资格后，当前投影必须重新计算或撤下；当前查看只显示 `content_projection_status=content_removed_by_policy`，历史评价台账以 `EVIDENCE_CENSORED` 保留非内容占位，不能继续展示被删除内容。投影撤销事件只追加，当前可查询投影可以失效，二者不矛盾。

`RawArtifact.storage_mode` 是判别联合类型，只允许 `full_bytes`、`licensed_excerpt`、`metadata_only`、`external_pointer`：

- `full_bytes` 与 `licensed_excerpt` 必须有关联的有效 RightsGrantVersion/AuthorizedContentScope、`ArtifactBlobBinding` 当前 Version、byte length、算法版本 checksum、envelope key reference 和 `PreservationManifestVersion`；excerpt 还必须保存 `authorized_content_scope_id` 与获准 byte/span 范围，且不得暗示保存全文。EvidenceScope 只能在之后定位事实支持，不能充当保存许可；
- `metadata_only` 禁止 source-content blob binding，只保存规范元数据、来源 URL、metadata record checksum 和数据库 preservation policy；它只能恢复元数据，不能恢复来源正文；
- `external_pointer` 的 RawArtifact 只保存捕获时不可变外部 URI 或 provider record key；禁止本地正文、excerpt checksum/key/binding，也禁止在 artifact 上保存或更新可变验证时间/链接状态字段。每次 200/404、重定向或失败检查都追加 `ExternalPointerCheckEvent`（复用 EventBase.event_id），当前可达性只由事件 as-of 投影；保存 `recoverability=external_uncontrolled`，链接未来失效不能算本系统恢复失败，也不能谎称永久保存。

内容寻址去重只允许发生在物理存储层。两个来源产生相同 payload 时仍创建各自的 `RawArtifact`，分别保存 provenance、rights snapshot、retention basis 和 `ArtifactBlobBinding`；不得用物理 hash 或共享 `StorageBlob` 充当来源/证据/法律身份。撤销来源 A 时立即断开 A 的 binding、artifact 访问和全部派生路径；只有来源 B 仍有独立合法依据且加密/法域兼容时，blob 才能继续为 B 保存。最后一个授权 binding 消失，或政策要求跨绑定删除该受保护内容时，必须级联删除 blob/key；不得以“另一来源字节相同”为由让 A 的 ID、缓存或向量继续取回正文。

`ArtifactBlobBinding` 与 `PreservationManifest` 都是稳定身份；用途、法源、状态、checksum/key/副本和恢复信息只进入各自不可变 Version，并由追加事件闭合。binding 授权、撤销和加密域变化生成 `ArtifactBlobBindingVersion`，撤销另追加 `BindingRevocationEvent`。撤销最后一个授权 binding 与生成 `BlobDeletionEvent` 必须在同一 serializable/fenced 事务中验证当前 rights epoch 和零授权引用：新 binding 要么先提交并阻止 blob/key 删除，要么在删除后使用新的 blob/key 明确重建；不得产生 stale/悬空 binding、复活已删除 key 或让竞态绕过撤权。

### 7.1 长期保存与恢复

“追加保存”只描述历史写入方式，不证明十年后仍能读取。每个 `storage_mode=full_bytes|licensed_excerpt` 且获准长期保存的 `RawArtifact` 必须关联不可变 `PreservationManifestVersion`，至少保存：原始字节长度、媒体类型、编码/压缩、一个或多个带算法版本的 checksum、envelope-encryption key reference 与轮换状态、访问域及 artifact/blob binding Version、独立存储副本 receipts、截至该 version 已知的 EventBase fixity/恢复 refs、保留状态、原始格式/解析器版本，以及格式迁移 derivative 的 provenance。“最近检查/恢复”只能由事件投影，不能成为原地更新字段。`metadata_only` 只保存 row checksum 与数据库备份/恢复政策；`external_pointer` 只保存捕获时 URI/provider key，后续可达性只由 ExternalPointerCheckEvent 投影。

原始字节不得因格式升级被转码覆盖；新格式只能作为带工具/解析器 provenance 的 derivative，并继承原 artifact 的权利、保留期与删除级联。摘要算法退役时创建新 `PreservationManifestVersion`、追加新 digest 与 `ChecksumMigrationEvent`，保留旧验证链，不改变 `artifact_id` 或版本身份。每次 scrub、修复、密钥轮换、恢复演练和格式迁移分别追加 `FixityCheckEvent`、`RepairEvent`、`KeyRotationEvent`、`RestoreTestEvent`、`FormatMigrationEvent`；fixity 检查结果是事件投影，不得更新一个“最近检查”权威字段。scrub 发现长度/checksum 不符时必须隔离损坏副本、禁止其进入抽取，并从独立副本恢复。

备份只有通过恢复演练才算可用。RPO、RTO、复制域、fixity/恢复抽样频率和 key rotation 属于版本化 preservation policy，具体数值在 feasibility spike 中冻结。恢复必须同时验证原始字节、稳定/版本 IDs、外键、rights/revocation epoch、删除墓碑、双时间和 ledger checkpoint。删除与撤权始终优先于保存目标；过期备份、旧副本或被撤销密钥不得恢复已删除内容，也不得形成明文旁路。

业务备份之外必须维护独立、签名且单调的 `ComplianceRevocationLedgerCheckpoint`，覆盖 deletion、rights/revocation epoch、binding/key 与个人删除高水位。每次恢复在开放网络、检索、缓存、模型或导出前生成 `RecoveryFence`，取得最新 checkpoint、证明未回滚并重放红删/销钥；checkpoint 缺失、回退或 canary 可取回时系统只能隔离并 deny-all，不能因旧备份内部自洽而启动。

### 7.2 删除 SLA

- 15 分钟内阻止继续展示和新检索；
- 24 小时内完成在线存储、索引与缓存级联删除；
- 备份按备份保留周期自然过期，最长 30 天，期间不可恢复到生产检索；
- 删除作业必须产生可验证清单和失败重试告警。

## 8. 分层采样与配额算法

### 8.1 原则

1. 已经合法采集的内容尽量全部进入逻辑不可变的原始档案；配额主要约束来源发现、抓取频率、计算资源和候选/展示选择，不用于事后销毁原始记录。第 7 节的合规删除是例外，使用 tombstone 保持审计链而不保留被删除正文。
2. 最低配额是“被看见的机会”，不是“重要性”判断。
3. 上限抑制信息量最大的群体垄断结果，但不隐藏重大事件；超出上限的内容仍留在档案并可进入“重大事件溢出区”。
4. 来源不足时形成显式覆盖债务，不用低质量、机器生成或重复内容填充。
5. 所有选择都记录 `selection_reason_codes`、策略版本和随机种子。
6. 同一候选可以拥有多个 `signal_types`（例如 emergence、diffusion）并出现在多个 `surface_sections`（例如弱信号栏、地区专题），但在探索正常预算中只能占用一个 `allocation_lane`。同时符合多个预算 lane 时记录 `eligible_allocation_lanes`，由确定性多队列匹配分配唯一 lane；落选/重复项由该 lane 下一候选补位。信号类型、产品栏目和预算 lane 不得都叫“通道”。
7. 执行前对候选集合做配额可行性检查；多维约束不可同时满足时，保留最小覆盖原则，输出不可满足约束及候选缺口，不静默改权重。

每个正式比较必须引用不可变 `RankingRuleManifest`。清单至少冻结：适用 `signal_types` 的 Pareto 核心维度、约束优先级、配额冲突求解、稳定 `candidate_id` tie-break、输入/特征/随机种子，以及 `required_comparison_keys[]` 和对应 `CoverageStratumVersion` IDs。比较任务不得在运行时为了等候更少数据而重写这组 keys，也不得用当前分层谓词重算旧水位或历史分母。

### 8.2 流行度视图与探索视图必须分离

系统维护两个不能混算的视图：

| 视图 | 回答的问题 | 是否使用分层曝光配额 | 可做的表述 |
|---|---|---|---|
| 流行度视图 `prevalence_lens` | 在当前可观察宇宙中，什么被更广泛地发布、转发或讨论 | 否 | “在已覆盖来源中占比/增长为……” |
| 探索视图 `exploration_lens` | 为避免被大体量输入淹没，还有哪些地区、语言、领域和小基数变化值得看 | 是 | “由覆盖保底/长尾/随机探索发现……” |

分层配额只能改变探索曝光，**不得用于估算全球热度、讨论占比或真实社会流行度**。流行度视图只使用 `O_prevalence` 中口径可比的传播观察；发生抽样时，每个传播观察必须记录已知纳入概率 `π`，使用逆概率权重等设计相容方法估计，并同时给出未加权值、置信区间、`acquire_observability`、`opportunity_completion` 和 `cursor_completeness`。若 `π` 不可知、来源选择不是概率抽样、游标不完整或跨平台口径不可比，只能报告“当前已覆盖传播记录中的描述性计数”，不得称为全球占比。

流行度视图测量“传播发生了多少”，因此不能把真正存在的转载、转发、独立发布和讨论节点按来源谱系全部去掉。它只消除同一传播节点因重试、重复抓取或镜像 URL 造成的技术重复，并分别显示发布节点数、转发/转载量、独立 publisher accounts、所有权集团和平台内归一化指标。一篇原稿被 100 个账号真实转载，可形成 100 个传播观察。

事实支持和来源独立性采用另一口径：同一原稿的 100 次转载仍只形成一个来源谱系，不能增加到 100 份独立事实证据。产品卡片把同一事件和谱系聚合成一张卡片或时间线以控制阅读负担，同时分别显示“传播规模”和“独立证据上下界”。卡片聚合不能反向修改传播计数。

探索视图按事件簇、来源谱系和所有权集团执行覆盖约束。探索视图中的“更多出现”不能反向证明流行度上升；流行度视图中的高体量也不能取消探索正常预算。

### 8.3 容量受限时的四条探索分配轨道

探索视图正常候选预算 `normal_budget B` 按以下 `allocation_lane` 分配。比例均为 `provisional_target`，需要通过 feasibility spike、时间切片回测、敏感性分析和偏差审计调整；局部快讯与重大事件溢出不占用或改写该预算：

| `allocation_lane` | 初始比例（provisional） | 作用 |
|---|---:|---|
| `coverage_floor` 覆盖保底 | 50% | 优先偿还地区、语言、领域、角色和媒介的覆盖债务 |
| `public_change` 公共变化 | 25% | 参考流行度视图中的体量、增长率、跨圈扩散和现实行动，不含个人兴趣 |
| `long_tail_novelty` 长尾新颖 | 15% | 选择历史低频、新概念、新关系及小基数加速项 |
| `random_exploration` 随机探索 | 10% | 从合格但低曝光的来源/覆盖格中进行可复现分层随机抽样 |

`random_exploration` 内部预注册 `unclassified_open_world` 子分层，但它不是第五条 allocation lane。初始 provisional floor 为该 lane 滚动 7 天实际名额的 30%（在上述 10% 初始 lane 配置下等价于 normal budget 的 3%）；只要存在足量高质量 eligible pool，就必须在 `domain_unknown`、`role_unknown`、`domain_and_role_unknown` 三组间确定性轮换，并继续按地区、语言、媒介、来源谱系和所有权集团分层。随机种子、轮换顺序、eligible pool manifest 与 SelectionDecision 必须冻结，不能由编辑者从 unknown 中事后挑“看起来有趣”的项目。

该子分层同时覆盖 detector 前置盲点：冻结 scope 的每个 CoverageItem 先物化 `PreDetectionExplorationEligibilityUnit/Decision`，保存资格谓词、质量/权限证据和 detector terminals；缺任一终态形成 gap。eligible 后才按冻结随机框物化 exploration unit/decision，selected 以 `ExplorationMaterialPlacement(not_a_signal=true)` 展示为“未解释探索材料”；不得先看内容只为赢家建资格记录，也不得伪装为 candidate、弱信号或流行度证据。

所有 domain/role unknown 候选都记录 `unclassified_dimensions[]`、`unclassified_eligibility`、资格/不资格理由、是否入选及未入选原因；按 edition 和滚动 7/30 天报告 eligible、selected、not-selected 数量与 selection/non-selection rate。无法分类本身不得成为不资格理由，也不得为了压低 unknown rate 强制贴现有领域/角色标签。若合格 unknown 候选不足，记录未用 floor 和候选缺口，空余额可回到同一 `random_exploration` lane 的其他预注册子层；不得用低质量、重复、无权或不安全内容填位。

如果实际容量足够处理全部合格内容，则不进行候选丢弃，但仍记录唯一 `allocation_lane` 以便审计。50%/25%/15%/10% 是待验证假设，不是自然法则；上线前必须以 40/30/20/10、60/20/10/10 等对照策略做敏感性测试并公开“哪些候选只因策略权重变化而入选”。

**本节是候选曝光配额的唯一规范来源。** 弱信号、日报和实时雷达规范只能引用 `coverage_policy_version`，可以定义各自的特征和门槛，但不得另设一套相互冲突的 70/20/10 或其他曝光预算。

### 8.4 覆盖保底选择

对维度 `d` 的标签 `v` 和窗口 `W`：

```text
share(d,v,W) = 该标签主归属的去重事件簇数 / W 内全部去重事件簇数（含 unknown）
deficit(d,v,W) = max(0, target_floor(d,v) - share(d,v,W))
normalized_deficit = deficit / target_floor
```

覆盖保底队列使用 max-min fairness：每次选择能偿还最多归一化债务、且来源独立性合格的候选。候选同时覆盖多个欠缺维度时可以提高优先级，但仍只在各维主标签下计数一次。

`unknown` 进入分母但不计入任何已命名标签的达标量。这样无法分类的内容不会让某个配额虚假达标，也不会因移出分母而让所有已知标签占比虚高；同时，domain/role unknown 的高质量候选仍受第 8.3 节 `unclassified_open_world` 子分层曝光保障，不能只“计入分母”却永远没有展示机会。

不得使用一个不可解释的总分覆盖所有维度。每次入选至少保留命中的维度、当前债务、来源谱系、质量门槛、`allocation_lane`、`signal_types` 和 `surface_sections`。

### 8.5 冷启动与基线预热

新增 publisher account、logical stream、语言能力、解析器、主题体系、采样口径或平台 API 时，系统必须使用 05 权威契约中的 `baseline_status`，不能把“刚开始看见”误报为“世界刚刚出现”：

| 状态 | 条件 | 允许的结论 |
|---|---|---|
| `baseline_unavailable` | 尚无完整计划机会或可比较历史 | 只展示原始事件、覆盖新增和探索发现；不得判断升温、衰退或总体占比 |
| `warming_up` | 已有连续完整机会，但尚未达到预登记基线长度 | 可显示带样本量的描述性变化；不得进入正式趋势或流行度比较 |
| `available` | 达到预登记基线长度、游标完整性和口径稳定门槛 | 可以进入对应范围的 `O_prevalence` 和趋势比较 |
| `coverage_shift` | 来源结构、游标、模型、分类或抽样口径发生不可桥接变化 | 断开旧序列并重新预热；旧数据仍保留为独立方法版本，同时记录 `COVERAGE_SHIFT` |

预热门槛按来源节奏和分析尺度配置，初始假设至少包含若干完整发布周期及一个完整比较基线；具体周期数属于 `provisional_target`，必须在 feasibility spike 中校准。冷启动和预热内容可以偿还“获得曝光机会”的覆盖债务，但不能被计入成熟趋势命中率，也不能以“系统首次见到”表述为“世界首次出现”。

### 8.6 重大事件溢出

重大灾害、战争、金融冲击等可能合理占用大量信息。系统应：

- 在热点栏目 `surface_sections.hotspot` 展示必要数量的相关事件；
- 将重复进展聚合为事件时间线；
- 保留探索正常预算中的 `allocation_lane.coverage_floor`，不让单一事件挤出所有其他地区和领域；
- 溢出项与探索基线分开计数，不能借“重大”绕过探索视图的集中度验收；
- 只有灾害/公共安全告警、重大政策或市场状态变化等版本化规则触发，不能由单一不可解释模型任意决定；
- 明确显示触发规则和“本窗口出现重大事件溢出”，而不是悄悄修改配额。

### 8.7 展示层最低多样性

展示约束只作用于探索栏。对每期或实时窗口中前 `N` 个探索事件：

| 探索事件数 | 地区 | 原文语言 | 领域 | 社会角色 | 媒介/证据类型 |
|---:|---:|---:|---:|---:|---:|
| 10–19 | ≥4 | ≥4 | ≥6 | ≥4 | ≥4 |
| 20–39 | ≥6 | ≥5 | ≥8 | ≥5 | ≥5 |
| ≥40 | ≥8 | ≥7 | ≥10 | ≥6 | ≥7 |

若合格候选不足，界面保留对应空位或显示覆盖债务，不能以重复、低质量内容补位。热点栏不受这些数量配额约束，但必须与探索栏并列存在，不能默认折叠探索栏。

“已选择”还必须落到冻结 `AttentionBudgetManifest` 所允许的实际 `AttentionPlacement`：channel/viewport、首屏或非折叠位置、页深、固定 K/阅读分钟、通知预算和日报—实时重复上限均可对账。`AttentionDeliveryFrameManifest` 在 placement/内容 arm 可见前冻结 audience eligibility、`audience_unit_type=account|device|token|household|person|organization`、`identity_namespace`、linkage/dedup 方法版本、误合并/漏合并验证结果及不确定性处理、invalid-traffic/prefetch/replay 规则和窗口 cap；规范 opportunity key 至少为 `eligible_audience_unit × audience_unit_type × identity_namespace × content/surface × bounded_window × channel`。同一 bot、预取器、push token 或重放不能膨胀同一冻结身份单位内的 reach；跨账号/设备/namespace 是否属于同一自然人无法可靠解析时必须单列 unknown，并以部分识别区间而非点值报告。

按该 frame 物化 `AttentionDeliveryOpportunity` 并与 PresentationDelivery 对账，分别报告 raw delivery、带明确单位标签的 unique eligible delivery opportunity 和 reading。一个自然人的 100 个合法账号不能在没有 person-level linkage oracle 时被称为“100 个独立受众”，100 人共享一个机构 token 也不能被称为“1 人”；此时只允许写 `unique accounts/devices/tokens delivered`。所有 `ReportClaim`/能力声明中的 reach predicate 必须复合绑定同一 `audience_unit_type/identity_namespace/linkage_method_version`；没有自然人级验证集与误差界时禁止使用未限定的 `unique people/audience reach`。placement 可达但合格 delivery=0 时 delivered exposure=0，不能宣称配额兑现或实际阅读。该判断不读取点击或个人兴趣特征。

## 9. 缺失状态与采集健康

“零条结果”必须针对 `collection_opportunity × purpose × coverage_scope` 区分且只能落入以下四种状态。分类标签 `unknown`、依赖关系 `dependency_unknown` 与缺失状态是不同字段，不得混用：

| 状态 | 含义 | 是否可推断讨论下降 |
|---|---|---|
| `OBSERVED_ZERO` | 相关机会已完成、目标游标范围完整、所需用途资格有效且解析正常，来源在该范围产生了可处理版本，但明确查询没有匹配记录 | 可以作为有限弱证据，仍需多机会、多谱系确认 |
| `COLLECTION_MISSING` | 属于 `O_acquire` 的计划机会未完成，或分页、序列、时间范围存在游标空洞 | 不可以；并附 `COLLECTION_OPPORTUNITY_MISSED`、`CURSOR_GAP` 或 `PAGINATION_INCOMPLETE` |
| `SOURCE_SILENT` | 机会完成且游标完整，但 publisher account 在该计划周期没有产生新版本 | 只可说明这个账号/流沉默，不代表社会讨论下降 |
| `NOT_OBSERVABLE` | 目标仍在 `U`，但对应机会或版本不属于本次所需的 `O_acquire/O_extract/O_model/O_train/O_signal/O_display/O_prevalence` | 不可以；并附 05 注册表中适用于该 purpose 的 canonical reason code；训练资格为 false 时记录 `PURPOSE_TRAIN_DENIED`，不能借用推理许可 |

四态在单个 `collection_opportunity × purpose × coverage_scope` 上互斥：不属于所需用途集合先判 `NOT_OBSERVABLE`；属于 `O_acquire` 但机会/游标不完整判 `COLLECTION_MISSING`；机会完整且账号未产生版本判 `SOURCE_SILENT`；只有来源产生了合格版本、完整处理后查询仍为零才判 `OBSERVED_ZERO`。每个状态必须记录 05 注册表中的 canonical reason codes、受影响的 logical stream、用途、地区/语言/媒介分层、起止时间、机会 ID 和游标证据。一个聚合范围只有在所有组成机会均有状态后才能汇总，并展示四态构成而不是强行压成单值；不能用空值代替四态。

### 9.1 衰退结论熔断

当相关覆盖格发生以下任一情况时，暂停生成“讨论减少/趋势衰退”结论，并按原因记录 `DATA_INSUFFICIENT`、`DEGRADED_COVERAGE`、`STRATUM_WATERMARK_LAG`、`BASELINE_WARMING_UP` 或 `COVERAGE_SHIFT`，不得另造同义原因码：

- 相关分层的 `opportunity_completion`、`cursor_completeness` 或 `acquire_observability` 低于对应的 provisional 门槛；
- 本次分析所需的 `O_prevalence` 或 `O_signal` 构成相对可比基线发生未校正变化；
- 关键地区或语言来源连续两个预期周期断流；
- 与历史基线相比，可采集来源谱系数显著下降，或 dependency unknown 比例显著上升；
- 解析成功率或时间戳完整率跌破验收阈值；
- 平台 API 策略变化造成观测口径不可比；
- 相关范围的 `baseline_status` 为 `baseline_unavailable`、`warming_up` 或 `coverage_shift`。

恢复后不能直接拼接断流前后的时间序列；应标注缺口，必要时重建可比基线。

## 10. 覆盖健康指标

指标必须在 L1/L2/L3 三层、每个相关用途集合中分别计算，并按报告窗口、滚动 7 天和滚动 30 天提供。下表的经验性数值均为 feasibility spike 前的 `provisional_target`。明确标为“合同硬门槛”的 100% 是确定性完整性/隔离不变量的零容错验收条件，不是对现实覆盖程度或模型准确率的统计承诺。

| 指标 | 定义 | v0.1 provisional target |
|---|---|---:|
| 采集可观察率 | 按机会权重计算 `acquire_observability` | 总体及每个必要地区/语言 ≥90% |
| 机会完成率 | 按机会权重计算 `opportunity_completion` | ≥95% |
| 游标完整性 | 按机会权重计算 `cursor_completeness` | ≥98% |
| 计划 cohort 连续性 | `planned_poll_cadence`/slot/cursor 变更前后，旧 `CollectionPlanManifest` 的计划机会、权重和历史指标是否仍可重放 | 100%（合同硬门槛）；新旧计划另报敏感性 |
| 描述/执行 cadence 偏离审计 | `SourceEndpointVersion.source_declared_update_cadence` 与适用 `CollectionPlanManifest.planned_poll_cadence` 的差异均有计划依据和敏感性报告 | 100%；来源描述字段不得直接生成分母 |
| 采集计划对账率 | 冻结 CollectionPlanManifest 确定性推导的 opportunity IDs 与物化 collection opportunities 一一对账 | 100%（合同硬门槛）；整窗调度器宕机造成的缺行补记 `COLLECTION_OPPORTUNITY_MISSED` |
| 端点映射不变性 | 端点/connector 拆并前后，同一逻辑计划的机会 ID、权重和游标范围是否不变 | 100%（合同硬门槛） |
| 来源注册 as-of 完整性 | edition 引用的 endpoint/account/owner versions 与 bindings 均在 snapshot as-of 可见，且有 `system_available_at` | 100%（合同硬门槛） |
| 分层版本 as-of 完整性 | watermark、计划机会分母和 edition 引用的每个 `stratum_id` 均绑定当时可见的 `stratum_version_id`，纳入谓词可重放 | 100%（合同硬门槛）；今天的分类边界不得回填历史 |
| 用途资格覆盖 | 各 `O_extract/O_model/O_train/O_signal/O_display/O_prevalence` 合格版本 / 对应已捕获版本 | 分用途、model/provider、分法域报告；不设混合总分；O_train 默认 false |
| 权利路由正确率 | 固定 RightsGrantVersion/AuthorizedContentScope/隐私夹具是否只进入允许的用途、processor/provider 与 byte/span/transform 范围 | 100%（合规硬门槛）；EvidenceScope 不得扩大授权 |
| 训练资格与删除可执行性 | 训练样本有明确 `O_train[model_id,purpose]`、可追踪 membership/epoch，且适用 checkpoint 可 unlearn 或可销毁重训 | 100%（合规硬门槛） |
| 解析成功率 | 在 `O_extract` 内成功得到许可范围内派生物的版本 / 应处理版本 | ≥98% |
| provenance 完整率 | 具备来源、版本时间、原始链接、捕获清单、谱系及依赖状态的版本占比 | ≥99.5% |
| 系统时间完整率 | `item_first_seen_at`、`version_observed_at`、`captured_at`、`version_available_at` 及 `clock_policy_id/clock_source_id/clock_health_snapshot_id/clock_skew_bound_ms/clock_health/ingest_sequence` 完整 | 100%（合同硬门槛） |
| 时钟政策符合率 | 非自报 attestation 满足至少 2 个独立健康源 quorum、60 秒 TTL、120 秒 holdover、provisional `max_skew_ms=5000` 与 restart/recovery 门禁的记录比例 | 100%（合同硬门槛） |
| 不可信时钟隔离率 | `time_quality=degraded` 对象被排除出精确窗口、提前量和跨分层比较的比例 | 100%（合同硬门槛）；记录 `CLOCK_UNTRUSTED` |
| 四态完整率 | 每个应汇总的机会/用途都有四种缺失状态之一及原因码 | 100%（合同硬门槛） |
| 发布/事件时间可见率 | 有可信 `source_published_at` / `event_time` 的版本占比 | 分类型报告，不以系统时间猜测 |
| 维度可分类率 | 五维均有标签或明确 `unknown` 状态的事件簇占比 | 100% |
| 未知率 | 任一核心维度为 `unknown` 的事件簇占比 | provisional alert ≤5%（分维报告）；只触发分类能力审计，不是候选质量失败或强制归类目标 |
| 未分类开放世界资格审计 | domain/role unknown 候选中，完整记录 `unclassified_eligibility`、原因和 SelectionDecision 的比例 | 100%（合同硬门槛）；无法分类本身不得作为不资格理由 |
| 未分类探索曝光 | `unclassified_open_world` selected / random_exploration 已用名额，并同时报告 eligible、selected、not-selected 与 selection/non-selection rate | 滚动 7 天 provisional floor 30%（合格池足量时）；不足时报告缺口，不以垃圾填位 |
| 分类质量 | 分语言分层标注集上的主标签质量 | 地域/语言/媒介 macro-F1 ≥0.90；领域/角色 macro-F1 ≥0.80 |
| 配额达成率 | 探索正常预算达到最低覆盖的标签数 / 应达标标签数 | ≥95% |
| 覆盖债务年龄 | 必需标签持续未达标的最长时间 | 日维度 <48h，轮转国家 <30d |
| 语言原文保留率 | 有权保存的版本中原文与译文均可追溯的比例 | 100% |
| 长期保存清单覆盖 | 获准长期保留的 RawArtifact 关联完整 `PreservationManifestVersion` 的比例 | 100%（合同硬门槛） |
| storage mode 合法率 | 四种 RawArtifact 联合类型只包含允许字段，并满足 binding/checksum/key/recoverability 约束 | 100%（合同硬门槛） |
| fixity 与损坏隔离 | 到期副本完成 scrub、发现损坏即隔离且不进入抽取的比例 | 100%；scrub 周期由 provisional preservation policy 冻结 |
| 恢复可用性 | 恢复演练同时通过字节、IDs/外键、rights、删除墓碑、双时间、ledger 与 RPO/RTO | 100% 通过最近适用演练；RPO/RTO 数值先为 provisional |
| artifact/blob 权利隔离 | 共享 blob 的每个 RawArtifact binding 独立授权；撤最后授权后 blob/key 清除 | 100%（合规硬门槛） |
| 最后 binding 事务线性化 | 并发撤销最后 binding 与新增授权 binding 不产生悬空关系、key 复活或越权正文 | 100%（合规硬门槛） |
| 去重准确率 | 固定标注集上的技术重复/近似重复识别 | 召回 ≥98%，错误合并 ≤1% |
| 谱系识别质量 | 固定转载/共同来源标注集上的来源谱系识别 | 召回 ≥95%，错误合并 ≤2% |
| 依赖未知率 | `dependency_unknown` 起点 / 全部候选起点 | 必须报告上下界；首版不设拍脑袋阈值 |
| 探索来源集中度 | 探索正常预算的最大谱系、最大所有权集团、前十大谱系占比 | 分别 ≤5%、≤10%、≤35% |
| 有效来源数 | `N_eff = 1 / Σ p_i²`，`p_i` 为探索正常预算谱系事件占比 | ≥30，且不低于冻结启动基线的 80% |
| 探索执行率 | 各 `allocation_lane` 实际使用量 / 版本化计划预算 | 90%–110% |
| 探索产出率 | 探索发现且 30/90 天后增强的主题数 / 探索主题数 | 只观察，不设首版硬目标 |
| 跨格空洞率 | 重点交叉覆盖格中超过目标时限未出现合格候选的比例 | ≤10%，且全部有原因码 |
| 发现时延 | 对有可信发布时间的条目，`item_first_seen_at - source_published_at` | 新闻/公告 P95 <30 分钟；同时报告可计算比例 |
| 版本可用时延 | `version_available_at - version_observed_at` | 分管道、语言、媒介报告 P50/P95 |
| 处理水位滞后 | `configured_data_cutoff - frontier_at`，并单列 `now - watermark_computed_at` | 分 stage/purpose/stratum 报告；不得隐藏最慢 required key |
| selection 完整前沿 | `configured_data_cutoff - selection_completeness_frontier` | 所有 eligible CoverageItem×required detector 在此前均有 terminal CandidateGenerationDecision，所有生成 candidate 均有 terminal SelectionDecision |
| 单期 cutoff lag | `cutoff_lag_minutes = scheduled_publish_at - data_cutoff` | `cutoff_lag_per_edition_hard_max_minutes=60`；只决定该 edition 能否为 normal |
| 滚动 cutoff lag | 最近冻结窗口的 `cutoff_lag_minutes` P95 | `rolling_cutoff_lag_p95_minutes_max=45`；只决定 `service_slo_status`，不得反向改写单期状态 |
| 服务 SLO 分母完整率 | `ServiceSLOSnapshot` 覆盖 `slo_config_version` 冻结窗口内全部 scheduled、published、failed、cancelled slots，且缺失/排除处理可重算 | 100%（合同硬门槛）；漏发或事后取消不得删出分母 |
| 调度清单对账率 | `ReportScheduleManifest` 确定性推导的 slot IDs 与预先物化 ReportScheduleSlots 一一对账 | 100%（合同硬门槛）；整窗宕机造成的缺行仍计 failed |
| 流行度估计资格率 | 属于 `O_prevalence` 的传播观察 / 已捕获传播观察 | 100% 才能作该范围总体估计；否则降级为描述性计数 |
| 快照复现率 | 冻结输入、派生工件、策略和种子重放相同候选 ID 与顺序 | 100%（合同硬门槛） |
| 个性化泄漏率 | 不同个人画像下全球基础输出差异 | 0%（隔离硬门槛） |

### 10.1 报告正常版、降级版与阻断门槛

报告状态必须由机器可读门禁决定。M0 将本节数值冻结为 `provisional_slo_v1`，仅用于 M1/M2 shadow；M1 feasibility 结束后只能通过版本化变更门禁产生 `production_slo_v1`，保留旧结果、差异和重跑证据，不得回写 provisional 历史。进入 production SLO 前所有报告必须显式标为 shadow，不作对外服务承诺。

`edition_status` 只看单期 hard limits 与完整性门禁：

| `edition_status` | `provisional_slo_v1` 单期门槛 | 输出限制 |
|---|---|---|
| `normal` | `cutoff_lag_minutes ≤60`；总体及必要地区/语言 `acquire_observability ≥90%`；总体 `opportunity_completion ≥95%`；解析成功率 ≥98%；`cursor_completeness ≥98%`；provenance ≥99.5%；四态和可信系统时间完整率 100%；`required_processing_frontier` 与 `selection_completeness_frontier` 均不早于 `data_cutoff`；发布宽限与全部权利/安全门禁通过 | 可以发布与健康范围一致的热点、探索和趋势；仍需显示 configured/data cutoff 与盲区 |
| `degraded` | 任一 normal 单期门槛未满足但仍可合法发布，例如 `cutoff_lag_minutes >60`、关键分层滞后、已隔离的 `CLOCK_UNTRUSTED` 输入，或总体 opportunity completion ≥80% 但 <95%；权利与安全门禁仍通过 | 必须显示触发字段、实际值、阈值、受影响分层和 canonical reason code；只发布健康范围的描述性结果与局部快讯，暂停受影响衰退、全球排名和跨层比较；cutoff 超限使用 `DEGRADED_CUTOFF_LAG` |

调度义务关闭时仍不能合法生成 normal/degraded edition，才追加 `ReportSlotStateEvent` 使 `ReportScheduleSlot.slot_status` 的 as-of 投影为 failed，且不存在 `PublicationEvent` 或 `ReportEdition`；此前的失败 attempts 及可合法公开的故障说明属于服务状态，不是 failed edition。成功原子提交的 PublicationEvent 将 slot 投影为 published；cancelled 也必须由 state event 明确表达。

`ServiceSLOSnapshot.service_slo_status` 独立计算：影子运行未积累 60 个计划 ReportScheduleSlots 时为 `warming_up`；达到样本门槛后，以对应 PublicationEvent 的 `publication_committed_at ≤ scheduled_publish_at + report_publish_grace_minutes` 计算滚动 30 天准时率，≥99% 且 `cutoff_lag_minutes` P95 ≤45 分钟时为 `meeting`，否则为 `breached`。`slo_config_version` 同时冻结计划 slot 分母、滚动窗口边界与时区、quantile estimator/舍入，以及漏发和取消的处理；分母必须与 `ReportScheduleManifest` 推导结果对账。未生成 edition 或因整窗故障漏建的计划 slot 仍留在准时率分母，cancelled 也不能消失；只有窗口开始前已由 schedule manifest 预注册且不可由运行方任意触发的排除规则，才能在主指标外另报 excluded cohort。PublicationAttempt、preview 或缺失 PublicationEvent 不能充当准时发布。滚动 P95 或总体平均不得把某个 cutoff lag 超过 60 分钟的 edition 改回 normal，也不得掩盖某地区或语言完全断流。局部范围可以健康、另一区域可以降级，最终 edition 状态取最保守的适用状态。

### 10.2 指标解释限制

- 配额达成说明“达成了自定覆盖政策”，不说明“还原了现实世界分布”；
- 有效来源数高不代表事实可信，只说明来源没有过度集中；
- 新颖度只相对于已有档案，不等同于对人类知识真正新颖；
- 用户的“认知新颖度”可以在个人层事后测量，但绝不能反馈到全球基础雷达的采集或排序。
- 探索视图的地区/语言均衡分布不能被解释成这些地区/语言在现实世界中同等流行。
- 跨平台发帖、浏览、转发等指标口径不同，必须先在各平台内部按可观察分母和活跃来源归一化；没有可靠换算时不得把原始数量直接相加。
- 上午逻辑窗口为 13 小时、晚间逻辑窗口为 11 小时；跨窗口比较必须使用每小时率、相同滚动窗口和来源可用性校正，不能直接比较条目总数。趋势探测使用连续滚动时间序列，08:00/19:00 只负责交付切片。

## 11. 重点交叉覆盖矩阵

MVP 不要求五维全组合，但下列高风险交叉必须建立每日/每周监控：

| 交叉维度 | 要回答的问题 | v0.1 provisional target |
|---|---|---|
| 地区 × 原文语言 | 是否只用英语媒体观察非英语地区 | 每个地区每 7 天至少 2 种当地主要语言来源；能力不足则红色告警 |
| 地区 × 社会角色 | 是否只看当地政府和大公司 | 每地区每 7 天至少覆盖 5 类角色，其中含地方社区/劳动者/公民社会之一 |
| 地区 × 媒介 | 是否只靠综合新闻转述 | 每地区每 7 天至少 4 类媒介，其中至少 1 类一手记录 |
| 领域 × 社会角色 | 是否只由权力和资源集中的机构定义一个领域 | 每领域每 7 天至少 3 类角色 |
| 领域 × 媒介 | 是否把“被讨论”误作“现实行动” | 每领域每 7 天至少有叙事类和行动/记录类证据 |
| 语言 × 来源谱系 | 多语言是否只是同一通讯社翻译 | 每语言每 7 天至少 4 个独立谱系 |
| 地区 × 领域 | 全球议题是否遮蔽当地变化 | 30 天内每个地区的 14 个领域至少 10 个有合格事件；空格需原因码 |

重点格清单每季度只基于覆盖审计调整，不根据用户兴趣调整。新增格保留生效日期，删除格需要说明原因。

## 12. 反信息茧房机制

### 12.1 架构隔离

- 全球采集、候选和排序服务不得读取个人记忆库；
- 全球基础雷达请求中不得包含 `user_principal_id`、用户 embedding、关注列表、点击或停留时间；
- 每次全球候选/选择运行冻结 standalone `GlobalRadarSnapshot`，只物化公共域输入和决定；对外实时表面只能从 RADAR_PUBLICATION current-head 获得该 ID，个人对话只能引用其 ID 读取，不能把私有上下文写回；
- 个人对话服务可以只读检索全球档案及个人记忆，但不能写入全球候选特征、`signal_types`、`allocation_lane`、`surface_sections` 或排序；
- 两个系统使用不同存储命名空间、服务账户和访问控制策略；
- 相同时间、来源快照、策略版本和随机种子下，任何用户得到完全一致的全球候选集合与排序。

用户可在界面做临时筛选，但“全球基线”始终可一键恢复，筛选不得改变后台基础快照。

### 12.2 产品与算法约束

- 热点、快速升温、弱信号、衰退和随机探索分栏呈现，不压成单一总榜；
- `coverage_policy_version` 中预留的 `random_exploration` 分配轨道及其 `unclassified_open_world` 子分层不得因点击率低或 taxonomy 无法解释而取消；具体 provisional 比例只由第 8.3 节拥有，其他章节不得复制成独立硬编码常量；
- 对高曝光地区、语言、平台、公司和人物的集中度上限只约束探索正常预算；不得改写流行度、局部快讯或重大事件溢出数据；
- 每条入选内容显示 `allocation_lane`、`signal_types`、`surface_sections` 和覆盖理由；
- 提供“本期没看见什么”而不只展示“看见了什么”；
- 采集源新增优先级由覆盖债务驱动；
- 用户反馈只用于纠错、界面和个人对话，不用于全球基线个性化，也不得进入全球采集/覆盖/detector/model/ranking 的离线训练、评价、调参或版本晋升；固定版本下不读取用户但下一版本由用户行为驱动，仍属于个性化泄漏。

### 12.3 偏差审计

每月审计：

- 英语中心、北美/欧洲中心和科技行业中心偏差；
- 官方、企业和资本声音挤压基层声音的程度；
- 通讯社转载造成的伪多样性；
- 平台机器人、公关投放和协调传播；
- 自动翻译、实体识别和情感/立场分析的语言差异；
- 分类器对同一事件在不同语言、地区和社会角色下的标签差异；
- 低资源语言、封闭生态、审查地区和线下群体的持续空白；
- 当前公共覆盖策略本身造成的新盲区。

审计结论和策略变更记录应面向用户可见。

## 13. 固定快照与可复现性

`ReportScheduleManifest` 必须在首个受影响名义窗口开始前冻结，保存 recurrence、`Asia/Shanghai` 时区、tzdb 版本、例外日、窗口边界、SLO 引用和确定性 slot ID 派生规则。计划分母从 manifest 推导并与预先物化的 `ReportScheduleSlot` 对账；系统整窗宕机导致未写出 slot 行，仍必须补建 failed slot/state event 并计入分母，不能借缺行消失。

每个上午/晚间义务预先创建不可变 `ReportScheduleSlot`，保存 `report_schedule_manifest_id`、名义窗口、计划发布时间、`slo_config_version` 和计划冻结时间。`slot_status=scheduled|published|failed|cancelled` 是截至查询 as-of 的事件投影，不是可更新字段：成功 PublicationEvent 投影为 published，失败或取消追加 `ReportSlotStateEvent`。完全漏发只有 failed slot/state event 和可选 PublicationAttempt；cancelled 默认仍在服务分母，只有窗口开始前由 manifest 预注册且运行方不能临时触发的排除规则，才能在主指标外另报 excluded cohort。

每次构建、预览或提交都追加 `PublicationAttempt`，但都不自动算发布。首次发布事务必须对 slot 获取 fence，以 CAS 验证尚未发布，复核最新 rights epoch 和全部 generation/selection/claim-generation terminal decisions，并在同一事务写入唯一 PublicationEvent、一对一 ReportEdition、完整有序的原始资讯 ReportItemPlacement 集合、全部 selected units 的 ReportCardPlacement 集合、完整 ReportClaim/ClaimExpressionVariant/ClaimCitation/RawSourceListingReference 集合、每 event 唯一 PresentationRenderPlan/全部 PresentationContentUnit，以及 initial ComposedPresentationSnapshot。数据库强制 `UNIQUE PublicationEvent(report_schedule_slot_id)`、`UNIQUE ReportEdition(publication_event_id)` 与 `UNIQUE ReportEdition(report_schedule_slot_id)`；即使两个 worker 使用不同 idempotency key，也最多一个成功，loser 只追加失败 attempt。

同一事务的 deferred constraint 必须分别证明：Edition 冻结的 ordered information-placement IDs 与对应 ReportItemPlacement 在 ID/arrival/order/count 上一致；ordered card-placement IDs 与所有 selected CandidateSelectionUnit/SelectionDecision 在 candidate/surface/order/count 上一致；claim units/decisions 与 manifest 的 min/max/ordinal/empty-state slots、selected containers、ReportClaims 一一闭合；expression variants/citations 与 required locale/channel、semantic slots、exact source/evidence/rights/citation role 一致；RawSourceListingReference 只绑定同 event 的 ReportItemPlacement 且不含 claim；kind-specific content-unit child 与最终 DOM/辅助文本/通知/导出在 channel/locale/typed-container/order/ref/hash 上双向相等；initial composed snapshot 与所有集合再次相等。不得先提交 Edition/Event 再补任一 placement、claim、variant、citation/listing-ref、render unit 或 snapshot。任何冲突都回滚整笔发布事务。

首次成功后的更正、说明、删除投影或其他内容变化，以 base edition 为 aggregate 执行 `REPORT_AMENDMENT` expected-head CAS。delta 只供审计；同一 amendment 事务必须物化新的完整 ComposedPresentationSnapshot，并令 event 同时引用 previous/new snapshot。当前读取只使用 initial publication 或最新连续 amendment head 的完整 snapshot，不能并行拼 base 与多个 deltas；不得创建第二个 initial PublicationEvent、覆盖 ReportEdition 或重算首次准时 SLO。`ReportEdition` 直接保存以下只读字段，不另造 05 未定义身份的 CoverageSnapshot 对象：

```text
report_edition_id
report_schedule_slot_id
report_schedule_manifest_id
report_pipeline_manifest_id
publication_attempt_ids[]
nominal_window_start / nominal_window_end / timezone
scheduled_publish_at
configured_data_cutoff
required_processing_frontier
selection_completeness_frontier
data_cutoff
snapshot_frozen_at
publication_committed_at
publication_event_id  # typed FK alias to EventBase.event_id；不是第二事件身份
processing_watermark_ids{}
required_pipeline_keys[]
comparison_scope
comparison_watermark
watermark_computed_at
edition_status: normal | degraded
edition_reason_codes[]
service_slo_snapshot_id
slo_config_version
publication_lag_minutes / cutoff_lag_minutes
clock_policy_id / clock_policy_manifest_hash
clock_health_snapshot_ids[]
clock_health_summary
time_quality_counts{}
source_registry_snapshot_id
global_radar_snapshot_id
collection_plan_id / collection_plan_manifest_hash
ranking_rule_id / ranking_rule_manifest_hash
required_comparison_keys[]
coverage_stratum_version_ids[]
target_opportunity_manifest_hash
observable_opportunity_manifest_hash
completed_opportunity_manifest_hash
cursor_evidence_manifest_hash
rights_snapshot_id
revocation_epoch
purpose_eligibility_manifest_hash
raw_manifest_hash
preservation_policy_version
preservation_manifest_version_set_hash
fixity_health_summary
restore_test_event_refs[].event_id  # EventBase FK；event_type=RESTORE_TEST
canonicalization_version
event_clustering_version
taxonomy_versions{}
coverage_policy_version
model_versions{}
prompt_versions{}
feature_manifest_hash
random_seed
selected_candidate_ids[]
generation_unit_ids[]
selection_unit_ids[]
claim_generation_unit_ids[]
candidate_generation_decision_ids[]
selection_decision_ids[]
claim_generation_decision_ids[]
ordered_report_item_placement_ids[]
ordered_report_card_placement_ids[]
ordered_report_claim_ids[]
ordered_claim_expression_variant_ids[]
ordered_claim_citation_ids[]
ordered_raw_source_listing_reference_ids[]
presentation_render_plan_id
ordered_presentation_content_unit_ids[]
initial_composed_presentation_snapshot_id
selection_reason_codes{}
health_summary
known_blind_spots[]
created_at
```

`created_at`、预览完成或成功构建 attempt 不等于发布；只有 fenced/CAS 与数据库唯一约束共同获胜，并原子创建首次 `PublicationEvent + ReportEdition`、两类 placements、claim obligations/claims/variants/citations/raw-listing refs、render plan 与 initial composed snapshot 后，`publication_committed_at` 才表示该 slot 已发布。ReportClaim 的 typed container 只能是同一 presentation event 的 ReportEdition 或 ReportCardPlacement，container 内 claim order 唯一。每个 selected card、世界概览和 candidate_count=0 的栏目有 manifest 要求的 claim slots；视觉/ARIA/locale variants 保留否定、模态、来源归属、数值/单位和推断标记，claim 附近 source title/quote 用 ClaimCitation 明示 role，无 claim 的原始资料只用 RawSourceListingReference 且禁止支持标签。最终输出多/少一句、变 hash、跨 event typed ref 或第二 render plan均阻断。提交同时校验最新 `revocation_epoch`、`data_cutoff` 和全部门禁；单次失败只追加 attempt，最终关闭且无成功提交才追加 failed `ReportSlotStateEvent`。

当前报告读取签发 `ReportViewToken(report_edition_id,presentation_head_event_id,head_revision,composed_snapshot_id,revocation_epoch,render_plan_hash,...)`；详情、分页、缓存和导出只能访问 token snapshot 成员。撤权先令内容视图不可用，再以 REPORT_AMENDMENT 在新 epoch 原子发布完整 redacted composed snapshot；不能把 base、旧/new delta 与读时墓碑混在一个响应。首次成功之后不得伪造第二次首次发布或改写首次准时率；滚动状态仍只来自 ServiceSLOSnapshot。

实时雷达使用独立的原子发布链，不能复用“snapshot 已写出”冒充 current view。RadarPipelineManifest 为每个 RadarSurface 冻结 required stages、scope/method epoch、selection/claim/render schema 与同 epoch head dominance；一次 RADAR_PUBLICATION 以 surface 为 aggregate 做 expected-head CAS，并在同一 serializable 事务闭合 GlobalRadarSnapshot、RadarCardPlacement、generation/selection/claim decisions、ReportClaims/ClaimExpressionVariants/ClaimCitations、PresentationRenderPlan/PresentationContentUnits 和最新 rights epoch。candidate_count=0 的每栏也有 required empty-state claim；worker/gap/撤权状态不能借静态世界空态模板。对外 current 只解析 `RADAR_SURFACE_HEAD` 的唯一最大连续 revision，不查询最新孤儿 snapshot，也不逐表取最大时间。

同一 scope/method epoch 内，snapshot 的 as-of/frozen time 严格前进且同 key processing/comparison/selection frontier、data cutoff、rights epoch 不倒退；不可桥接变化使用新 epoch、`COVERAGE_SHIFT` 和重新暖机。读取签发含 surface/head revision/snapshot/presentation-event/rights-epoch/render-plan/query-shape 的短期 RadarViewToken，在首字节前重验；RadarContinuation 还签名绑定 token hash、snapshot/event/query shape/cursor，详情和导出成员做复合 membership。S2 token 请求 S1 card/cursor 返回 `RADAR_VIEW_TOKEN_SCOPE_MISMATCH`。撤权使旧 epoch head 整体不可展示，直到新 epoch snapshot 完整重算；应用层只能返回完整旧 view、完整新 view、`RADAR_VIEW_RECOMPUTING` 或 `RADAR_VIEW_UNAVAILABLE`，不能交付旧排序加新墓碑、跨 snapshot 卡片或前端自由文本。

### 13.1 原始条目、版本与修订时间

系统必须区分：

| 字段 | 定义 |
|---|---|
| `registered_at` | 来源、发布者账号或端点第一次进入注册表的受控系统时间 |
| `source_published_at` | 来源声明的发布时间，可未知或不可信 |
| `source_updated_at` | 来源声明的更新时间，可未知 |
| `event_time` | 现实事件发生时间，可为区间或推断值，只服务事件时间线 |
| `item_first_seen_at` | 系统第一次观察到这个逻辑 item 的时间；创建后永不因重抓、修订或来源日期变化而回填 |
| `version_observed_at` | 系统第一次检测到这个确切来源版本的时间；每个新来源版本（包括格式/元数据变化）均有自己的值 |
| `captured_at` | 该版本原始快照安全落盘的系统时间 |
| `version_available_at` | 该原始版本通过许可与安全门禁、开始可供下游读取的时间；被拒绝时允许为 null，但拒绝决定必须可审计 |
| `revision_type` | `RevisionAssessmentVersion` 字段：`format_only`、`metadata_update`、`correction`、`retraction`、`substantive_addition` 或 `unknown_revision` |
| `reportability` | `RevisionAssessmentVersion` 字段：独立于修订类型的 `non_reportable`、`reportable` 或 `unknown`；决定该 revision 是否形成新的报告信息到达 |
| `decision_system_available_at` | 该 RevisionAssessmentVersion 完成规则/模型/权利检查并可供查询的系统时间；不能回填到 raw version |

必须满足 `item_first_seen_at ≤ version_observed_at ≤ captured_at`；若版本获准下游读取，还必须满足 `captured_at ≤ version_available_at`。初始版本的前两个时间通常接近，但不能通过复制来源发布时间伪造。`RawItemVersion` 只保存不可变字节/元数据差异及其 hash，不拥有会被分类器改判的最终语义；每个非初始版本关联稳定 `RevisionAssessment`，其不可变 `RevisionAssessmentVersion` 另存 assessment rule/model/run、reason、输入 diff 与被取代 assessment version。后续重分类必须追加新 `RevisionAssessmentVersion + SupersessionEvent`，绝不修改 RawItemVersion 或旧 assessment。

首次条目逻辑归属由 `item_first_seen_at` 决定；后续在当时 as-known 的 RevisionAssessmentVersion 中为 `reportability=reportable|unknown` 的版本按 `version_observed_at` 形成新信息到达，`non_reportable` 不形成新 arrival。`format_only` 必为 non-reportable；correction、retraction 和 substantive addition 必为 reportable；metadata update 必须按是否改变既有时间线、作者归属或其他报告语义判定，不能一概忽略；unknown 保守进入更新流。assessment 后来从 unknown/reportable 改为 non-reportable 或反向升级时，原 `information_arrival_at` 不改；系统按新 decision 的 `decision_system_available_at` 追加 `REVISION_ASSESSMENT_CORRECTION` 并重算当前投影，不得倒填旧运行。实际能否进入该期还必须同时满足 `information_arrival_at ≤ comparison_watermark`、原始版本 `version_available_at ≤ snapshot_frozen_at`、选用的 assessment `decision_system_available_at ≤ snapshot_frozen_at`，以及必需派生对象 `system_available_at ≤ snapshot_frozen_at`。

所有关键系统时间使用 UTC，并随记录保存 `clock_policy_id`、`clock_source_id`、不可变 `clock_health_snapshot_id`、`clock_skew_bound_ms`、经受控时间服务评估的 `clock_health`、写入域内单调递增的 `ingest_sequence` 和 `time_quality=trusted|degraded`。ClockHealthSnapshot 保存观测、quorum、skew、TTL 和 sequence continuity；worker 自报“healthy”不是信任证据。M0 `clock_policy_v1` 的 provisional oracle 固定为：至少 2 个独立健康源形成 quorum，`max_skew_ms=5000`，health TTL 60 秒，无 quorum holdover 最长 120 秒；任何 wall-clock rollback、sequence 重用或超界 skew 立即降级。恢复需在 5 分钟内连续 5 次通过 quorum 健康检查并完成 sequence continuity 验证。允许时间源、闰秒/smear 和重启规则也写入 manifest；M1 只能通过版本化变更和窗口归属敏感性测试调整这些数值。

`ingest_sequence` 只在自己的写入域内排序；跨域 happens-before 的权威关系必须写入不可变 `EventCausalParent(event_id,parent_event_id,edge_system_available_at,queue_proof_id?)`。它使用复合主键、自环检查、parent 不晚于 child 的时间约束，以及 serializable/deferred DAG 门禁拒绝长环和两个并发反向边；同域 parent sequence 必须更小，跨域必须有 queue proof。默认因果边与 child EventBase 同事务创建且不可事后追加；允许迟到边的 adapter 必须保存 edge system time，旧 as-of 不可见。对象 JSON 的 `causal_parent_event_ids[]` 只是投影，不能代替权威 FK，也不能直接比较两个域的本地序列。`item_first_seen_at/version_observed_at` 只能由受控登记服务赋值，不能采用采集 worker 的任意本地时钟。quorum 不足、健康证明 TTL 过期、holdover 超过 120 秒、时钟倒退、sequence 重用、跨节点偏移超阈值、闰秒处理异常、重启后序列异常或时间源不可用时，受影响对象标 `time_quality=degraded` 和 `CLOCK_UNTRUSTED` 并进入隔离；它们不得参与精确窗口归属、提前量或跨分层比较，edition 至少降级。恢复必须满足上述连续检查和 sequence continuity 门禁并完成隔离输入重放，不能由 worker 清除自身异常。来源自报时间不能修复系统时钟。

### 13.2 派生对象与双时态

每个 TranslationArtifactVersion、来源注册 Version、CanonicalItemVersion、SourceLineageVersion、EventClusterVersion、RevisionAssessmentVersion、ObservationVersion、FeatureArtifact、SignalCandidate、SignalVersion、SelectionDecision 和 ReportClaim 必须按各自在 05 archetype registry 中的字段契约记录 `system_available_at`：该记录完成计算、权利检查并开始能被下游查询的时间。任何回放只能读取 `system_available_at ≤ as_of` 的记录，不能因其证据的来源发布时间较早而向过去回填。

每个进入处理管线的输入还必须携带 `information_arrival_at`：初始 item 使用 `item_first_seen_at`；后续在当时可见 RevisionAssessmentVersion 中为 `reportability=reportable|unknown` 的版本使用该版本的 `version_observed_at`；non-reportable revision 不产生新的 arrival。派生对象继承其全部输入中最晚的 information arrival。它表示“这批世界信息何时进入系统视野”，不能用处理完成时刻、assessment 决定时刻或重跑时刻覆盖。`system_available_at/decision_system_available_at` 回答输出或判断何时可查询，`information_arrival_at` 回答输入信息属于哪一个到达前沿，两者不得互换。

完整双时间只适用于 05 第 5.1 节 time-profile registry 登记为 `bitemporal_version_time` 的 immutable records；该 registry 的对象清单是唯一所有者，第 7.2 节只展开字段契约。它们保存 `valid_from`、可选 `asserted_valid_until`、`valid_time_status=unknown|not_applicable`（有效时间未知或不适用时必填）、`system_from`、`system_available_at`、`as_of/run_mode` 与输入/方法版本；闭合只由查询时可见的 EventBase/SupersessionEvent 投影 `projected_system_to/projected_valid_to`。

登记为 `derived_record_time` 的 FeatureArtifact、CoverageItem、SignalCandidate、CandidateGenerationDecision、SelectionDecision、ClaimGenerationUnit/Decision、ReportClaim、ClaimExpressionVariant、ClaimCitation、RawSourceListingReference、PresentationRenderPlan/PresentationContentUnit、AnalysisRun 与 ModelOutputArtifact 使用 `recorded_at/system_available_at/as_of/run_mode/input record IDs`；`operational_record_time` 的 ReportItemPlacement、ReportCardPlacement、RadarCardPlacement 等对象使用 `recorded_at/system_available_at` 与对象专属业务时间。二者都不自动拥有 `system_from` 或业务 valid time。SourceRegistrySnapshot、ClockHealthSnapshot、RightsSnapshot、CorpusScopeSnapshot、ServiceSLOSnapshot、GlobalRadarSnapshot 与 ComposedPresentationSnapshot 是 standalone snapshot，只有自己的 snapshot ID、`snapshot_frozen_at/system_available_at/as_of` 和物化成员，不拥有稳定 snapshot parent 或 valid/system closure。RawItemVersion 继续使用第 13.1 节 observe/capture/available times。当前《统一数据、时间与决策契约》（`docs/05-canonical-data-and-time-contract.md`）第 5.1/7.2 节是对象原型、time profile、字段和闭合语义的 M0 权威；本规范只定义覆盖与报告侧政策，不得另造冲突字段。

### 13.3 处理水位、比较水位与局部快讯

每期必须冻结非空 `ReportPipelineManifest.required_pipeline_keys[]`，至少覆盖该 edition scope 的 eligibility/normalization、candidate generation、selection 和 claim generation。每个 key 绑定 `stratum_version_id`、purpose、DetectorManifest、terminal record type 与 completeness oracle；SLOConfig 只能引用该 manifest，不能从“实际启动或产出了哪些任务”反推 required keys。漏阶段或 detector 零运行必须留下 WatermarkGap，不能用空候选集让完整性 vacuous pass。

`processing_watermarks{}` 是 map，不是单一时间。键为 `pipeline_stage × purpose × stratum_id`；每个稳定 `stratum_id` 必须通过该运行冻结且 as-of 可见的 `CoverageStratumVersion` 解析地区、语言、媒介、角色和纳入谓词，报告另存 `stratum_version_id`。分类谓词变化只能追加新版本；旧水位、机会分母和历史 edition 继续引用旧版，不能用今天的边界回填。每个值是一个结构体：

```text
{
  pipeline_stage,
  purpose,
  stratum_id,
  stratum_version_id,
  frontier_at,
  watermark_computed_at,
  scope_snapshot_id,
  terminal_state_counts,
  unclosed_gaps[],
  cursor_checkpoint_id
}
```

`frontier_at` 是连续信息到达时间轴上的完成前沿，可形式化为“使得该 key 下所有 `information_arrival_at ≤ t` 的应处理输入均进入可审计 terminal state，且对应 collection opportunities/content cursors 没有已知空洞的最大 `t`”。它受最早未完成输入、未闭合机会或游标缺口约束，不能跳过空洞。没有新版本的静默区间只有在计划机会完成且游标/完整性代理证明未漏采时才能推进前沿；因此它也不能退化为“已观察版本的最大 arrival”。失败、隔离或权利排除必须有 terminal reason；若它们导致比较数据缺失，水位可以被计算但该 scope 必须降级并附 canonical reason code。只记录最大 `system_available_at`、最后成功任务时间或当前时钟都不能构成 watermark。慢管道今天刚处理完一条上周旧数据，只能关闭上周 arrival 的缺口，不能把 frontier 跳到今天。

每个跨来源、跨语言、跨地区或全局比较必须声明 `comparison_scope`，并从冻结 `RankingRuleManifest.required_comparison_keys[]` 取 key 集；清单同时冻结这些 keys 对应的 `CoverageStratumVersion` IDs，再以 `min(processing_watermarks[key].frontier_at)` 生成 `comparison_watermark`。用于比较的各侧只能读取 `information_arrival_at ≤ comparison_watermark` 且 `system_available_at ≤ snapshot_frozen_at` 的派生对象；水位较快的一侧不能用额外数据获得不公平的“升温”优势。`comparison_watermark/configured_data_cutoff/data_cutoff` 属于信息到达时间轴，`snapshot_frozen_at/system_available_at` 属于系统可查询时间轴，禁止跨轴直接比较。`watermark_computed_at` 单独说明水位何时被计算，不能替代水位本身。

报告实际截止点不能只取配置时间：

```text
required_processing_frontier = min(processing_watermarks[key].frontier_at
                                   for key in required_pipeline_keys)

data_cutoff = min(configured_data_cutoff,
                  required_processing_frontier,
                  selection_completeness_frontier)
```

`selection_completeness_frontier` 是连续 candidate-generation/selection 输入前沿：此前每个冻结 scope 中 eligible CoverageItem×required detector 都有 terminal `CandidateGenerationDecision(candidate|no_candidate|failed)`，每个生成 candidate 又都有 terminal `SelectionDecision`（入选或未选及理由）。合法 no-candidate 必须有输入和理由；任务没运行、崩溃或漏写 decision 保持 WatermarkGap。不能用空候选集、“已选中的最新对象”或只保存入选项推进前沿。edition 只能读取 `information_arrival_at ≤ data_cutoff` 且 `system_available_at ≤ snapshot_frozen_at` 的对象；`cutoff_lag_minutes` 必须用 `scheduled_publish_at - data_cutoff` 计算。configured/data cutoff、processing/selection 两个限制前沿和差值都必须展示。

不能为了让全局排名更“新鲜”而在运行时删除持续偏慢的 key。删 key 必须生成新的 `RankingRuleManifest` 和 coverage policy version，双跑旧/新规则，发布被排除分层、`STRATUM_WATERMARK_LAG` 或 `COMPARISON_WATERMARK_REDUCED`、以及排名敏感性；该 edition 必须为 `degraded`，同一 global comparison scope 不得因删 key 被标为 normal。

局部范围的管线已经健康完成、但全局 comparison watermark 尚未追上时，可以发布“局部分层快讯”。快讯必须展示其 `comparison_scope`、自己的 processing watermark、未完成的 required keys 和“不可据此判断全球排名/跨区域趋势”提示；它不占探索正常预算，也不能触发全局衰退或扩散结论。全局水位追上后，系统追加正式比较结果并链接原快讯，不能静默改写。

### 13.4 报告窗口与补录

每个初次 item 创建唯一 `ReportableArrival(arrival_kind=initial_item)`，时间为 `item_first_seen_at`，subject 使用 `kind=object/type=RawItem`；每个当时 assessment 为 reportable/unknown 的 revision 创建唯一 `arrival_kind=content_revision`，时间为 `version_observed_at`，subject 使用 `kind=record/type=RevisionAssessmentVersion`。记录保存 `subject_identity_id/subject_identity_kind/subject_concrete_type`，数据库对 `(subject_identity_id, subject_identity_kind, subject_concrete_type, arrival_kind, arrival_semantics_version)` 建唯一键。assessment 后续重分类不改原 arrival；新判断按 `decision_system_available_at` 创建 `arrival_kind=assessment_correction`，并通过 amendment/placement 修正当前投影。

每次把 arrival 放入报告都创建 `ReportItemPlacement`，必填 `report_edition_id`、`presentation_event_id`、`information_arrival_id`、`item_order`、actual slot、`is_first_publication` 和可选 backfill FK。presentation event 只能是所属 edition 的 PUBLICATION 或 REPORT_AMENDMENT EventBase 事件；数据库强制同一 presentation event 内 arrival 与顺序唯一，并以 partial unique key 保证每个 `information_arrival_id` 最多一条 `is_first_publication=true`。presentation event/edition 归属和完整 placement delta 由复合 FK/deferred constraint 验证；首发冲突回滚整个 publication/amendment 事务。首次漏期后下一期展示仍是唯一 first placement，并引用 `backfill_of_report_schedule_slot_id`；连续两期、重试或 amendment 不能重复宣称首发。

每个 selected CandidateSelectionUnit 另创建一个 `ReportCardPlacement`，必填 `presentation_event_id`、`selection_unit_id/selection_decision_id`、`candidate_id`、`surface_section`、`card_order` 与渲染用 `signal_version_id`（candidate-only 时显式标记）。同一 presentation event 内 selection unit 及 surface+card order 分别唯一；unit/decision/candidate/surface 必须复合一致且 outcome=selected，not_selected/failed 不得产生卡片。卡片重复展示由下一期新的 selection unit/placement 表达，不能伪造 ReportableArrival 或借用 `is_first_publication/backfill`。

逻辑窗口采用北京时间半开区间：

- 上午版：`[前一日 19:00:00, 当日 08:00:00)`；
- 晚间版：`[当日 08:00:00, 当日 19:00:00)`；
- `item_first_seen_at` 等于 08:00:00 的条目只进入晚间逻辑窗口；等于 19:00:00 的条目只进入下一上午逻辑窗口；
- 每个 ReportScheduleSlot 显式保存 `configured_data_cutoff`，每个 edition 按第 13.3 节引用 `report_pipeline_manifest_id/required_pipeline_keys[]`，并保存 `required_processing_frontier`、`selection_completeness_frontier`、`data_cutoff`、`processing_watermarks{}` 和 `comparison_watermark`；configured cutoff 由滚动可用时延和编排预算形成版本化配置，不能覆盖保守 min 公式，并须展示预计遗漏率和实际限制项；
- `item_first_seen_at` 属于上一逻辑窗口，但原始版本或必需派生对象未在上一期 `snapshot_frozen_at` 前达到允许查询的 terminal state，因而未进入上一冻结清单的条目，在下一期记录 `PROCESSING_BACKFILL`；不得把 `version_available_at/system_available_at` 与 arrival-axis 的 `comparison_watermark` 直接比较；
- 来源较早发布但系统本期才首次发现的条目，按本期 `item_first_seen_at` 归属，记录 `DISCOVERY_DELAY` 并显示 `source_published_at`；它不是上一期处理补录；
- `reportability=reportable|unknown` 的 revision 按 `version_observed_at` 归属更新逻辑窗口，并按语义使用适用的 `CORRECTION`、`RETRACTION` 或 `MATERIAL_UPDATE`；若版本或派生物未在该期 `snapshot_frozen_at` 前达到允许查询的 terminal state，则下一期记录 `PROCESSING_BACKFILL`，不能伪装成新 item；
- 来源只改变自报时间或其他元数据时不得改写系统 arrival 历史；若变化影响既有时间线或作者归属，必须在新的 RevisionAssessmentVersion 保存 `revision_type=metadata_update`、`reportability=reportable` 和 `decision_system_available_at`，按 `version_observed_at` 进入更正区，不能静默重排旧 edition；只有当时可见 assessment 明确 non-reportable 的 metadata update 和 format-only revision 不生成新候选；
- `event_time` 只用于事件时间线和历史分析，不决定首次报告归属；
- 已发布快照不可因迟到条目静默改写。

固定快照可因合法删除产生受控缺口；删除后追加 ReportAmendment/REPORT_AMENDMENT 记录投影变化。复现时应得到相同选择结果，或在原位置显示 `content_projection_status=content_removed_by_policy` 并记录 `DELETED_BY_POLICY`；不能覆盖首次 ReportEdition，也不能用新内容自动替补并声称是原快照。

100% 可复现指：基于冻结的原始清单、规范化结果、事件簇、特征清单、策略和随机种子，确定性重放候选选择得到相同 ID、顺序和理由。它不要求第三方生成模型在未来重新调用时逐字产生相同文本；模型原始输出必须作为快照工件保存，重新计算的差异另做漂移报告。

## 14. MVP 边界

### 14.1 MVP 必须实现

- 10 个互斥宏观区域、全球/跨区域类、10 种正式原文语言和 2 种试验语言；
- 14 个领域、8 类社会角色、9 类媒介/证据；
- 采集计划覆盖不少于 200 个目标 publisher accounts/logical streams、120 个独立来源谱系，并按计划机会达到第 10 节 provisional 门槛；这些数量须经 feasibility spike 验证；
- 每个地区至少 10 个可观察独立谱系、每种正式语言至少 6 个可观察独立谱系；
- 30 天内触达至少 60 个国家或地区；
- connector、SourceEndpoint/PublisherAccount/OwnerGroup stable IDs 与 Versions、SourceRegistrySnapshot、logical stream、collection opportunity 和 content cursor 的版本化映射，以及冻结 `planned_poll_cadence` 的 `CollectionPlanManifest`；
- record 级 RightsGrantVersion/AuthorizedContentScope/PurposeAuthorization 用途权利集合（含默认 false 的 `O_train[model_id,purpose]`）、训练 membership/删除路径、`revocation_epoch` 原子复核、来源注册表、所有权字段、provenance 图、I0–I4、`dependency_unknown` 和独立性上下界；
- RawItem/CanonicalItem/EventCluster 稳定身份、不可变版本及事件式闭合；
- 获准长期保存 RawArtifact 的 PreservationManifestVersion、`FixityCheckEvent/RepairEvent/ChecksumMigrationEvent/KeyRotationEvent/RestoreTestEvent/FormatMigrationEvent`、独立副本与格式迁移 derivative；StorageBlob 物理去重与 ArtifactBlobBinding Version、`BindingRevocationEvent/BlobDeletionEvent` 法律身份隔离；
- 四种缺失状态、采集健康监控和衰退结论熔断；
- 版权 R0–R3、隐私 P0–P3 分级和级联删除；
- item/version/derived archetype/双时态、`ClockSource/ClockHealthSnapshot/ClockPolicyManifest` 可信时钟隔离、`CoverageStratum/CoverageStratumVersion`、`baseline_status`、处理/比较/selection 前沿、`RankingRuleManifest`、非空 ReportPipelineManifest、CandidateGenerationDecision/SelectionDecision/ClaimGenerationDecision，以及 ReportScheduleManifest/ReportScheduleSlot/PublicationAttempt/PublicationEvent/ReportEdition/ReportAmendment/ReportableArrival/ReportItemPlacement/ReportCardPlacement/ReportClaim/ClaimExpressionVariant/ClaimCitation/RawSourceListingReference/PresentationRenderPlan/ComposedPresentationSnapshot/ServiceSLOSnapshot 拆分；
- ReportEdition 只允许 `edition_status=normal|degraded`；
- schedule slot 独立使用 scheduled、published、failed、cancelled 四态，服务状态只存在于 ServiceSLOSnapshot；
- 四条 `allocation_lane` 的探索正常预算、random_exploration 内预注册 `unclassified_open_world` 子分层、传播与事实支持双口径和固定快照；
- RadarSurface/RadarPipelineManifest、standalone GlobalRadarSnapshot、RadarCardPlacement、RADAR_PUBLICATION current-head CAS、RadarViewToken 与撤权 epoch 整体失效，并与个人记忆架构/权限隔离。

来源总数只是最低启动条件，不能代替维度和交叉格验收。

### 14.2 MVP 明确不承诺

- 覆盖所有国家、语言和互联网平台；
- 抓取登录墙、私密社群和法律不允许保存的全文；
- 对所有音视频进行实时多语种识别；
- 对低资源语言达到与中英文完全相同的 NLP 水平；
- 用社交媒体数量代表民意；
- 将“讨论减少”直接解释为现实重要性下降；
- 以任何准确率承诺预测黑天鹅。

### 14.3 扩展顺序

扩展由覆盖债务和审计驱动，而不是用户点击驱动：

1. 补足 MVP 地区 × 当地语言 × 当地发布者的空格；
2. 扩展至 20+ 原文语言和 120 个国家/地区的 30 天触达；
3. 增强专利、招聘、采购、物流、开源代码等行动型数据；
4. 引入合规的当地社交/社区数据和多语种音视频转录；
5. 在质量门槛达到后继续扩展低资源语言、线下合作数据和历史档案。

每次扩展都必须先建立语言/解析评测集和来源合规策略，再计入正式覆盖率。

## 15. MVP 验收标准

### 15.1 数据与覆盖

- M0 先完成 connector/来源/权利/成本 feasibility spike 并冻结 `provisional_slo_v1`，记录每个 provisional target 的可达性、样本、成本和失败原因；M1 至少运行连续 60 个计划 shadow editions，M1 结束后方可经版本化门禁产生 `production_slo_v1`；在该版本获批前，后续 edition 仍须标为 shadow；
- 影子运行必须包含上午/晚间边界、来源断流、游标空洞、端点拆并、重大事件高峰、周末低流量、新来源冷启动和权利变更；
- SourceRegistrySnapshot、`SourceEndpointVersion.source_declared_update_cadence`、`CollectionPlanManifest.planned_poll_cadence`、RankingRule manifest 和受控时钟字段完整率 100%；描述/执行 cadence 差异可审计，未知关系使用明确状态；
- 每个来源发现周期先由 `SourceDiscoveryProgramManifest` 确定性展开全部 `SourceDiscoveryFrameOpportunity` 及唯一 run/skipped/failed terminal；run 与 `SourceDiscoveryFrameManifest` 一对一，frame 内再展开全部来源 opportunities/decisions，两个层级任一缺口都不能被已成功运行的 frame 或已准入来源掩盖；
- 正式能力比较必须在 arm 数据可读前冻结 EvaluationArmManifest；系统、热门、随机、编辑、champion/challenger 各 arm 的 GenerationUnit/Decision、完整有序 OutputSnapshot、EvaluationObligations 与 Results 集合相等，共享同一输入范围、K 和 OutcomeFrame；
- 每个 EvaluationCorpusSnapshot 中潜在验证 EvidenceUnit 都有 ValidationEvidenceEligibilityUnit/Decision，将支持、反证、排除和 failed 全量闭合到结果；每项纳入证据的生产者/调查者/测量操作者又有 ValidationEvidenceProducerExposureUnit/Decision，系统诱导产生的验证不得冒充独立复现；
- M1 退出前必须通过 preservation manifest、独立副本 fixity/修复、全垂直切片恢复、格式 derivative、hash agility、密钥轮换及 artifact/blob 绑定删除测试；仅有备份作业成功记录不算可恢复；
- 计划采集机会、游标、publisher account、endpoint 和 connector 映射可追溯；端点拆并不改变逻辑分母；
- `acquire_observability`、`opportunity_completion`、`cursor_completeness` 及各用途资格按第 10 节口径计算，并达到 feasibility spike 后冻结的 normal/degraded 门槛；
- artifact/version 权利路由、`revocation_epoch` 在途任务处置与发布原子复核、四缺失态、系统时间/序列、事件式闭合和个人隔离等合同硬门槛达到 100%；
- 五个维度的滚动 7 天配额达到 feasibility spike 后冻结的目标（初始假设 ≥95%），未达标项全部生成原因码和覆盖债务；
- 探索正常预算中的英语、任一地区、任一领域、任一所有权集团和任一来源谱系均不突破相应上限；流行度与局部快讯不被这些上限改写；
- 重点交叉格满足第 11 节 SLA，不能只用单维总量通过验收；
- 每种正式原文语言使用独立且不与训练/提示样例重叠的评测集。首轮 provisional 假设为：语言识别 macro-F1 ≥0.98；数字、日期和否定等关键语义保留率 ≥98%；实体与引语归属 F1 ≥0.95；每种语言至少抽取 500 条并由合格双语评审复核，严重意义反转率 ≤1%。feasibility spike 后冻结门槛；未达标语言只能保持试验状态，不得计入正式覆盖率；不得以英语结果替代。

### 15.2 必做情景测试

| 测试 | 输入 | 通过条件 |
|---|---|---|
| 端点拆并不变性 | 将一个承载同一 publisher account/logical stream 的端点拆成十个，再合并为新端点并更换 connector | `collection_opportunity` ID、权重、计划游标范围和历史覆盖率不变；只新增版本化 endpoint mapping |
| 来源注册历史隔离 | 2027 年集团收购两个原本独立的 2026 publisher accounts，并重分类其中一个角色 | 追加 Account/Owner versions 和物化不可变 version-ID 清单的新 SourceRegistrySnapshot；2026 as-known 仍使用当年所有权/角色/rights/cadence，旧独立性与社会角色指标不变；动态重跑注册查询不得改变旧结果，2027 及显式 retrospective 结果另存 |
| 慢源计划分母 | 月更端点在无计划任务的小时没有新内容，到了月度计划周期却未执行 | 小时窗口不制造机会或失败；月度机会由 `CollectionPlanManifest` 生成且返回 `COLLECTION_OPPORTUNITY_MISSED` |
| 采集机会漏建对账 | CollectionPlanManifest 已冻结确定性 opportunity IDs，但采集调度器在整个计划窗口宕机且机会行从未创建 | 对账从 manifest 重新推导并补建全部预期机会，追加 CollectionOpportunityStateEvent、记录 `COLLECTION_OPPORTUNITY_MISSED`，opportunity completion/coverage health 下降；不得因没有 Capture 或原始机会行而从分母消失 |
| 降低采频不美化 | 来源描述 cadence 仍为 5 分钟，却把 `planned_poll_cadence` 从每 5 分钟静默改为每日 | 旧 plan cohort 指标不变；新 `CollectionPlanManifest`、change event、偏离依据和双跑/敏感性齐全；不得改写 `source_declared_update_cadence` 或只因机会减少而提高健康度 |
| 机会与游标完整性 | 某计划机会成功返回第一页，但后续分页 token 失败 | attempt audit 记录部分执行，但该机会不进入 `C_acquire`，`opportunity_completion` 与 `cursor_completeness` 均下降，状态为 `COLLECTION_MISSING`，并记录 `PAGINATION_INCOMPLETE` 或 `CURSOR_GAP`；不能以 HTTP 成功冒充完整采集 |
| grant/scope 用途权利 | 同一 record 的 RightsGrantVersion 允许本地元数据抽取和最多显示 200 字，AuthorizedContentScope 禁止全文、provider A、人物关系和其他 transform | PurposeAuthorization 引用 grant/scope；该 record 只进入对应 `O_extract/O_model.local/O_display` 索引投影，显示原子核对不超过 200 字，不进入禁止的 `O_model.provider[A]/O_signal`；不能套用来源级默认值 |
| grant/scope/resource 防拼接 | Grant A 允许 record version X，Grant B 的 Scope B 允许更宽 span；尝试用 Grant A + Scope B 或把 scope 只绑 stable item ID | allow 复合 FK 失败并回滚；AuthorizedContentScope 必须绑定同一 `rights_grant_version_id` 与确切 `(resource_record_identity_id, resource_record_type)`。多 scope 操作逐项授权，不能隐式 union |
| 证据范围不得授权 | EvidenceScope 指向正文某段可支持命题，但没有覆盖该 span 的 RightsGrantVersion/AuthorizedContentScope | 可保存证据关系的非内容审计事实，但不得据 EvidenceScope 抓取、保存、展示或传给模型；补充合法 grant/scope 后才能形成相应用途资格 |
| 推理与训练许可隔离 | 某版本允许 provider A 单次推理，但未明确允许任何 training/fine-tuning | 推理任务可按 provider 授权执行；所有 `O_train[model_id,purpose]` 均为 false 并记录 `PURPOSE_TRAIN_DENIED`，训练集、微调任务和 provider retention/training 路径中的样本数为 0 |
| 训练样本撤权与不可 unlearn | 一条已进入可追踪训练集的显式授权样本撤权；一个 checkpoint 可验证 unlearn，另一个不可 | 样本从后续训练 snapshot 移除；前者完成验证 unlearning，后者禁用/销毁并从清洁 snapshot 重训；membership、epoch、checkpoint 和处置可审计 |
| 撤权竞态 | 分别在模型调用中、报告渲染中和发布提交前提高资源 `revocation_epoch` | 旧 epoch 任务取消或 tainted，输出不持久化/展示；原子发布返回 `REVOCATION_RACE_BLOCKED`，读时投影不能被旧缓存绕过 |
| 极端输入集中 | 95% 新输入来自美国/英国科技媒体 | 原始档案和流行度视图如实显示该输入分布；探索候选与展示仍满足地区、语言、领域配额和集中度上限，二者不得混算；重大事件可进入溢出区 |
| 转载风暴 | 同一原稿被 100 个真实账号转载 | 流行度形成 100 个传播观察；事实支持形成 1 个来源谱系；产品聚合为一张卡片/时间线并同时显示两种口径 |
| 地区断流 | 一个地区的计划机会集体超时或游标断档 | 相关机会为 `COLLECTION_MISSING`，opportunity/cursor 指标下降，触发健康告警并暂停该地区衰退结论 |
| 四缺失态 | 分别注入“来源产生了合格但不匹配查询的版本”、采集/分页失败、健康轮询但账号未产生版本、目的用途无权观察四种场景 | 互斥地产生 `OBSERVED_ZERO`、`COLLECTION_MISSING`、`SOURCE_SILENT`、`NOT_OBSERVABLE`，均带 purpose、scope 和 canonical reason code；聚合显示构成，不得用 `unknown` 或单一空值代替 |
| 个人画像隔离 | 用两个完全相反的用户画像 A/B 请求同一 GlobalRadarSnapshot | snapshot 不含任何用户/当前问题/点击/记忆字段；全球候选 ID、特征向量、`signal_types`、`allocation_lane`、`surface_sections`、顺序和选择理由逐项完全一致 |
| 实时 current-head 原子性 | 两个 worker 以不同 snapshot/rights epoch 并发刷新同一 RadarSurface，并在 snapshot、card、claim、render-plan、head event 各阶段注入崩溃与旧 worker 重放 | expected-head CAS/连续 revision 只允许一个 RADAR_PUBLICATION winner；对外只读该 event 的完整 snapshot checksum。预览/孤儿 snapshot 不可见，head 不回退，不混合不同 snapshot 的 feature/selection/card/claim/render unit |
| 实时撤权线性化 | 请求依次读取排序、卡片、首字节/分页时提高 revocation epoch，同时交错旧/新重算 | 旧 head 整体失效；同一 RadarViewToken 只能得到完整旧 view、完整新 view、`RADAR_VIEW_RECOMPUTING` 或 `RADAR_VIEW_UNAVAILABLE`。不得交付旧排序加新墓碑、跨 epoch 卡片、旧缓存或让旧 epoch worker 成为 head |
| 实时 token 成员越界 | 用 S2 的有效 RadarViewToken/continuation 请求 S1 的 card、cursor 与 export selection，另修改 query shape | RadarContinuation 签名绑定 token hash/snapshot/presentation event/query shape/cursor；所有返回成员复合属于 S2，任一 S1/变形请求返回 `RADAR_VIEW_TOKEN_SCOPE_MISMATCH`，不能只验 token 签名 |
| 呈现文本完备性 | selected card/世界概览分别构造零 claim、漏 required slot、跨 container claim，并在标题、tooltip、alt text、Markdown 与推送中额外拼一句未经登记推断 | ClaimGenerationUnit/Decision、ReportClaim、PresentationRenderPlan/PresentationContentUnit 与最终 DOM/序列化单元双向相等；零/漏 claim 返回 `CLAIM_COLLECTION_INCOMPLETE`，额外/变 hash 文本返回 `UNAUDITED_PRESENTATION_CONTENT`，整笔发布失败 |
| 空栏目动态主张 | 分别构造真实零候选、worker 未运行、WatermarkGap 与撤权重算，并尝试统一渲染签名静态模板“没有值得关注的信号” | candidate_count=0 激活 section empty-state required claim，绑定 selection completeness/watermark/coverage/rights/观测四态；真实零与缺失不可混称，worker/gap/撤权按 manifest failed/unavailable；静态世界主张返回 `CLAIM_COLLECTION_INCOMPLETE` |
| amendment 累计视图 | 初版有 A/B，两条连续 amendment 依次删除 A、替换/重排 B，并让读取、缓存与导出交错 | 每个 head CAS 物化完整 ComposedPresentationSnapshot；ReportViewToken 只读取某个 committed head。任一响应不得同时出现 A、旧 B、新 B 或混合 base/delta/redaction |
| 多语言与无障碍等价 | 中文 claim 含否定、数值单位、来源归属和“可能”，英语视觉/ARIA/通知 variant 分别删掉限定或改数值 | 每个 locale/channel/role ClaimExpressionVariant 绑定翻译/生成工件和 semantic-equivalence；required slots 保留全部语义，失败用 `CLAIM_EXPRESSION_NOT_EQUIVALENT` 阻断，即使各 hash 自洽 |
| 引用与主张错配 | claim A 由证据 A 支持，却把合法来源 B 标题/引文邻接为 evidence，或把 context citation 标成 supports；另用 nullable ClaimCitation 表达无 claim 原始资料 | ClaimCitation.report_claim_id 必填且绑定 exact scope/rights/role；只有 entails/source_asserts 可用证据标签。原始资料只用无 claim 的 RawSourceListingReference 绑定 ReportItemPlacement，两类 XOR |
| item/version 时间边界 | `item_first_seen_at` 恰为 08:00:00/19:00:00；旧文章本期首次发现；同一 item 后续 reportable 更正；另有 format-only/non-reportable metadata update；上一窗口 item 的派生物在上一期 `snapshot_frozen_at` 后才可用 | 初次 item/revision 分别创建唯一 ReportableArrival 并按半开区间归属；旧文记录 `DISCOVERY_DELAY`；non-reportable revision 不创建 content-revision arrival；每次展示有 ReportItemPlacement，partial unique key 只允许一条 first publication；处理迟到者以 nominal-slot backfill FK 补录，不跨时间轴比较 availability 与 arrival watermark |
| 来源时间语义变化 | 来源把已报道事件的自报发布时间从本周改为一年前，导致旧时间线含义变化 | 系统 item/version 时间不改；另建 RevisionAssessmentVersion，保存 `revision_type=metadata_update`、`reportability=reportable` 与 `decision_system_available_at`，以 `version_observed_at` 进入更正区；不得把判断写回 RawItemVersion 或静默重排旧 edition |
| 修订判断重分类 | 某 revision 先被判断 unknown/reportable，后来公共证据证明只是 non-reportable 格式变化 | 原 RawItemVersion、旧 assessment 和 `information_arrival_at` 均不改；追加新 RevisionAssessmentVersion、SupersessionEvent 与 `REVISION_ASSESSMENT_CORRECTION`，按 `decision_system_available_at` 重算当前投影，旧 edition 保持 as-known |
| 派生对象双时态 | 证据早已发布，但 observation 在 `snapshot_frozen_at` 后才完成并取得 `system_available_at` | 当期回放不可读取该 observation；下一期可见且不会把系统可用时间回填为来源时间；字段符合 05 契约 |
| archetype 对应的追加与闭合 | 同一 RawItem 出现更正，EventCluster 随后拆分 | RawItem 只追加新 RawItemVersion，使用 observe/capture/available times且不伪造 supersession 区间；EventCluster 追加新 bitemporal EventClusterVersion 与 SupersessionEvent，由 EventBase as-of 投影 `projected_system_to/projected_valid_to`；两类旧行 checksum 均不改 |
| archetype 后缀陷阱 | schema 生成器看到 SourceRegistrySnapshot、ClockHealthSnapshot、FeatureArtifact、RawItemVersion 与 CanonicalItemVersion | 逐对象读取 05 第 5.1/7.2 节：standalone snapshots 没有稳定 parent/closure，FeatureArtifact 没有 system_from/valid_from，RawItemVersion 使用 observe/capture/available times，只有登记的 CanonicalItemVersion 使用完整双时间；不得按 Version/Snapshot 后缀批量加列 |
| event subtype 单一身份 | 对同一状态转换同时尝试写 EventBase.event_id 和一套 subtype 专用第二 ID | schema/门禁拒绝第二事件身份；SupersessionEvent 等 typed API 以同一 EventBase.event_id 作 PK/FK，因果边引用 EventBase |
| 不可信时钟隔离与恢复 | worker 自报 healthy，但采集节点快 8 分钟、派生节点慢 12 分钟；随后独立健康源少于 2 个、TTL 超过 60 秒、holdover 超过 120 秒、NTP 回拨或 sequence 重用 | 生成不可变 ClockHealthSnapshot；`clock_policy_v1` 的 `max_skew_ms=5000`、quorum/TTL/holdover 门禁否决自报。域内 `ingest_sequence` 与跨域 EventCausalParent/queue offset 保持顺序，JSON parent array 仅为投影；对象标 `time_quality=degraded`、`CLOCK_UNTRUSTED` 并隔离，只有 5 分钟内连续 5 次 quorum 健康检查且 sequence continuity 验证通过后才恢复 |
| 分层边界历史隔离 | 2027 年修改某地区/语言分层的纳入谓词，使一批 2026 items 改变归属 | 新增 CoverageStratumVersion 并保留旧版；2026 watermark、机会分母、RankingRuleManifest 与 edition 仍引用当时 `stratum_version_id`，历史指标不变；新边界结果仅作为 2027 或显式 retrospective 输出 |
| 分层水位与局部快讯 | 某地区/语言管线领先，另一必要分层严重滞后 | `processing_watermarks{}` 保留各键；全局比较按 `required_comparison_keys[]` 使用保守 `comparison_watermark`；领先内容只能发局部分层快讯，不得声称全球排名或跨区升温 |
| 删除慢分层 key | RankingRule manifest 从 required keys 删除一个持续偏慢语言 | 生成新 manifest/policy、双跑、`edition_status=degraded`、排除范围与排名敏感性，并记录 `STRATUM_WATERMARK_LAG` 或 `COMPARISON_WATERMARK_REDUCED`；同一 global scope 不得标 normal |
| 旧数据晚处理水位 | 慢管道今天才处理完一条上周到达的数据，但其后仍有多个未处理输入 | 新输出的 `system_available_at` 为今天，`information_arrival_at` 仍为上周；只能关闭对应旧缺口，processing frontier 不得跳过其后的未处理输入；另存 `watermark_computed_at` |
| 静默区间水位 | 某账号数小时没有新版本；一组机会有完整游标/代理证据，另一组只因没抓到内容就自称完成 | 前一组可把 `frontier_at` 推进至已证明边界并标 `SOURCE_SILENT`；后一组停在最早未证明空洞并记录 `WATERMARK_INPUT_GAP`，不能用最大已观察 arrival 或空结果推进 |
| 有效 cutoff 保守最小值 | 08:00 slot 的 configured cutoff=07:55、required processing frontier=07:45、selection completeness frontier=07:30 | `data_cutoff=07:30`、cutoff lag=30 分钟；edition 不读取 07:30 后对象，并显示 selection 是限制项；不得用配置或已选对象最新时间冒充 cutoff |
| 空候选集不得 vacuous pass | ReportPipelineManifest 要求两个 detectors；一个合法完成并输出 no-candidate decision，另一个任务未启动且没有 CandidateGenerationDecision | 未启动 key 保持 WatermarkGap，selection completeness frontier 不推进，edition 不得 normal；只有补齐 terminal CandidateGenerationDecision 及所有 candidate 的 SelectionDecision 后才能闭合 |
| 首次发布并发与幂等 | 同一 schedule slot 先预览、两次提交失败；随后两个不同 idempotency key 的 worker 并发提交，并重放 winner | fence/CAS、slot/event/edition 三个唯一约束只允许一个 winner；同一事务写入唯一 PublicationEvent、一对一 ReportEdition、完整 information placements 与全部 selected-units card placements，两套 deferred constraint 分别校验。preview/loser 只留 attempts；任一 placement 冲突回滚整笔事务，重放不产生第二次首次发布 |
| 首次版后修订 | 已发布 ReportEdition 随后发生事实更正、说明补充和合法内容投影撤下，并并发提交两个 amendments | base edition aggregate 的 expected-head CAS 只接纳一个 head；同一事务追加 ReportAmendment、共享 EventBase.event_id 的 REPORT_AMENDMENT subtype 与完整 placement delta，每个 placement 的 presentation event/edition 归属可验证；不覆盖首次 edition、不创建第二个 initial PublicationEvent，也不重算首次 SLO |
| edition 与失败 slot 门禁 | 分别构造达到 normal、只达到 degraded、禁止发布合同失败三组输入 | 前两组各原子创建一对一 PublicationEvent/ReportEdition，版次状态分别为 normal/degraded；第三组只追加失败 PublicationAttempt 与 failed ReportSlotStateEvent，as-of slot 状态为 failed，不得创建 PublicationEvent 或 ReportEdition；总体平均不能掩盖局部断流 |
| 单期与滚动 SLO 隔离 | 60 期中 58 期 cutoff lag=5 分钟、2 期=180 分钟，滚动 P95 仍低于 45 | 两个 180 分钟 edition 因单期 hard max=60 标 degraded 和 `DEGRADED_CUTOFF_LAG`；滚动值只生成新的 ServiceSLOSnapshot 及其 `service_slo_status`，不得反向改写单期状态 |
| 服务分母与取消防美化 | 同一冻结 SLO 窗口含正常发布、完全漏发和运行方事后 cancelled slots，并尝试删掉失败/取消行 | `ServiceSLOSnapshot` 按 `slo_config_version` 冻结的 slot 分母、窗口/时区、quantile/舍入和缺失规则重算；漏发与 cancelled 均留在分母，只有窗口开始前命中预注册排除规则者另行报告且不计入 |
| 调度清单漏建对账 | ReportScheduleManifest 已冻结上午/晚间 recurrence 与确定性 slot IDs，但系统在整个晚间窗口宕机且未创建 slot 行 | 对账补建对应 ReportScheduleSlot 与 failed ReportSlotStateEvent，计入服务分母；不得因没有 PublicationAttempt 或原始 slot 行而消失 |
| M0 到 M1 SLO 晋级 | 用 M1 feasibility 数据修改门槛 | M0 的 `provisional_slo_v1` 与 shadow 结果保持不可变；只能新增版本化 `production_slo_v1`、差异、重跑和批准记录 |
| 固定快照复现 | 使用同一原始清单、冻结特征、策略版本和随机种子确定性重放 | 候选 ID、顺序和理由 100% 一致；合法删除位置显示占位符 |
| 可观察分母退化 | 一批目标逻辑流失去采集权利或技术路径 | 其计划机会仍留在 `U`，`acquire_observability` 下降并形成债务，不能移除机会使指标改善 |
| 流行度与探索隔离 | 对同一输入分别运行两个视图 | 探索配额不会改写流行度计数；无法确定纳入概率时产品不输出“全球占比” |
| 探索上限边界 | 热点和局部快讯集中于同一地区/来源，但探索正常预算具备多样候选 | 集中度上限只约束探索 normal budget；流行度如实计数，快讯与溢出单列，任何一方都不偷占探索配额 |
| 开放世界未分类曝光 | 注入一批 provenance/权利/安全/独立性均合格、但无法映射 14 领域或 8 类角色的新型现象，并混入重复、低质和无权 unknown 内容 | 合格项记录 `unclassified_eligibility` 并进入 random_exploration 的预注册子分层/轮换；合格池足量时滚动 7 天达到该 lane 30% provisional floor，selected/not-selected rate 可审计。不得强制归类；不合格项不填位，余额只回流同 lane |
| 冷启动与预热 | 新接入语言/平台突然带来大量此前未见主题，随后解析器口径改变 | `baseline_status` 依次为 baseline_unavailable/warming_up/coverage_shift；不得生成正式升温、衰退或“世界首次出现”；达到冻结门槛成为 available 后才进入 O_prevalence |
| 依赖未知上下界 | 十个媒体共同引用可能相同但无法确认的匿名消息源 | 输出 independence lower/upper bound 和 `dependency_unknown_count/share`；上界不得写成十份独立事实证据 |
| 版权/个人数据级联删除 | 对一条已进入原文库、搜索、向量、缓存、人物关系和衍生投影的内容发起有效删除 | 在 SLA 内完成级联删除；当前投影重算/撤下并显示 `content_removed_by_policy`，评价台账仅留 `EVIDENCE_CENSORED` 非内容占位 |
| 低熵墓碑防枚举 | 删除内容是电话号码或常见短句，攻击者枚举公开候选 | 墓碑不暴露裸内容 hash；仅保留受控 HMAC 或随机 receipt，未授权者不能验证候选内容 |
| RawArtifact storage mode 联合类型 | 分别构造四种合法 mode，并给 licensed_excerpt 缺 AuthorizedContentScope、给 metadata_only 添加内容 binding、给 external_pointer artifact 添加 excerpt/checksum/key/可变验证与状态字段、给 full_bytes 缺省 key/manifest version | 四种合法夹具通过；licensed_excerpt 具备 `authorized_content_scope_id` 与获准 span；metadata_only 具备规范元数据、URL、record checksum/DB preservation policy；external_pointer artifact 只有捕获时 URI/provider key 和 `recoverability=external_uncontrolled`，后续检查追加 ExternalPointerCheckEvent 并由事件投影当前状态；非法组合均被拒绝 |
| 物理去重与独立法源 | A/B 两个合法来源产生相同字节并共享 StorageBlob；先撤 A，再撤 B | 两个 RawArtifact、rights 和 ArtifactBlobBinding Versions 独立；撤 A 后 A 不可取回而 B 仍可用；撤最后授权 binding 后 blob/key 级联清除，物理 hash 不充当法律身份 |
| 最后 binding 并发竞态 | 一个事务撤销 blob 的最后授权 binding，另一事务同时新增兼容的授权 binding | 撤销生成 ArtifactBlobBindingVersion/BindingRevocationEvent；最后撤销与 BlobDeletionEvent 在同一 serializable/fenced 事务核验当前 rights epoch 和零授权引用。新增若先提交则阻止删除，删除若先提交则新增使用新 blob/key；无 stale/悬空 binding 或旧 key 复活 |
| fixity 损坏修复 | 人为翻转一个存储副本字节，另一独立副本正确 | `FixityCheckEvent` 记录 checksum/length 不符；损坏副本隔离且不进入抽取；按 PreservationManifestVersion 从独立副本恢复并追加 `RepairEvent` |
| 全切片恢复演练 | 从冻结备份恢复完整 M1 垂直切片 | 追加 `RestoreTestEvent`；原始字节 checksum、稳定/版本 IDs、外键、rights、删除墓碑、双时间和 ledger checkpoint 全匹配；RPO/RTO 达到冻结 policy |
| 格式迁移 | 将旧媒体/文档迁移到可读新格式 | 追加 `FormatMigrationEvent`；原始 artifact 字节和 ID 不变；新格式是带 parser/tool provenance 的 derivative；两者 rights 与删除级联一致 |
| hash agility | 当前 checksum 算法进入退役流程 | 新增 PreservationManifestVersion、追加新算法 digest 与 `ChecksumMigrationEvent`，保留旧验证链；不重写 artifact ID、版本身份和 receipt，抽样双算法校验通过 |
| 加密密钥轮换与删除优先 | 轮换 envelope key 后模拟旧 key 不可用，并包含一条已撤权内容 | 追加 `KeyRotationEvent`；获准内容可由新 key 恢复且无明文旁路；已删除/撤权内容不能从备份或旧 key 恢复；key access 可审计 |
| 恶意附件 | 来源提供含宏、脚本、提示注入或伪装格式的附件 | 在隔离区阻断执行和模型摄入，只保留许可范围内的安全审计信息 |
| 翻译错配 | 英文译文和非英语原文同时存在 | 覆盖计入原文语言；原文、译文和翻译模型版本可追溯 |
| 未知所有权 | 新来源无法确认控制方 | 标为 `owner_unknown` 并进入审计，不被当作独立所有权证明 |
| 重大事件挤压 | 单一全球事件占输入 80% | 时间线聚合且启用溢出区，探索 normal budget 的 allocation lanes 仍按政策执行 |
| CoverageItem 同义复制 | 100 个并发事务对同 scope/policy/input/strata/role 提交不同随机 ID | 规范 projection key 与 UUIDv5 重算后只存在一个 CoverageItem/generation unit；重复或漏物化产生 WatermarkGap，真实 policy/role 变化才生成新 ID |
| 跨域因果 DAG 攻击 | 分别写入自环、二节点/长环、晚于 child 的 parent、旧事件迟到边和两个并发反向边 | EventCausalParent 复合主键、自环/时间/sequence/queue-proof 与 serializable DAG 门禁阻断；并发至多一个提交，旧 as-of 不因迟到边改变，合法图稳定拓扑回放 |
| 来源发现候选漏账 | 冻结当地媒体目录返回 1,000 个规范逻辑流，只为 10 个易接入来源创建 SourceDiscoveryDecision，其余不落库 | SourceDiscoveryFrameManifest 的目录/分页 receipt 确定性展开 1,000 个 SourceDiscoveryOpportunity 且各有唯一 admit/reject/duplicate/failed 终态；缺 990 项形成 discovery gap，阻断来源发现覆盖声明，不能以进入 U 后的完整率掩盖 |
| 来源发现 frame 选择性消失 | 计划每月运行 100 个地区×语言×渠道发现批次，但只为准入率最高的 10 个创建内部完整的 SourceDiscoveryFrameManifest | 结果可读前激活的 SourceDiscoveryProgramManifest 必须展开 100 个 SourceDiscoveryFrameOpportunity 及唯一 run/skipped/failed terminal；10 个 run 与 manifest 一对一，其余 90 个仍在 program 分母并形成 gap，不能用 10 个完整 frame 声称跨格发现覆盖/多样性达标 |
| 候选条件化来源招募 | 候选 C 出现后按其关键词招募 50 个站点并转载 C | SourceDiscoveryDecision/RecruitmentCohort 标记 candidate-conditioned；这些来源不得为 C 提供扩散、独立确认或流行度升级，预冻结独立留出来源仍可 |
| 连续扫描多重检验 | 365 天每小时动态扫描一万主题并在每窗重置 BH | 所有 test/candidate/no-candidate 写入同 SequentialHypothesisFamily ledger；漏账/重置使用 `MULTIPLE_TESTING_UNCONTROLLED`，不得确认或晋升 |
| online-FDR 看值后重排 | 预建并最终入账全部 10,000 个 null tests，但先读全部 p 值，再按 p 从小到大安排 ledger sequence 或只给小 p 分配大 alpha_i，且总 debit 守恒 | 每项 logical_test_order/threshold reservation 在统计量可见前锚定；alpha_i 只由严格先前 ledger history 重算。看值后排序/分配即 `MULTIPLE_TESTING_UNCONTROLLED`，不能因机会全量和 wealth 守恒通过 |
| online p/e 条件有效性 | 两个顺序 null tests 共用同一冻结输入 `U`，生成边际均匀但条件相关的 `p1=U,p2=1-U`；机会、顺序、阈值和 wealth 全部合法入账 | 每项绑定不可变 TestStatisticInputSnapshot、filtration/dependence lineage 与 conditional-validity method；验证器必须在允许的 `history_<i` 下确认 p-value 条件超均匀或 e-process 超鞅前提。只有边际校准、共享输入未归簇或结果依赖抽样/停止时使用 `MULTIPLE_TESTING_UNCONTROLLED` |
| 检测前开放世界探索 | 高质量、合法 OOD/unknown 输入让所有 detector 返回 no-candidate | 仍确定性物化 PreDetectionExplorationUnit/Decision，并按冻结随机框产生 `not_a_signal=true` 的 ExplorationMaterialPlacement；不冒充信号或 prevalence |
| 探索注意力可达性 | 热点占满首屏/通知，探索项虽 selected 但只在折叠区或第十页 | AttentionBudgetManifest 与实际 AttentionPlacement 对账固定 K、viewport/fold/page、通知和日报—实时重复；不可达时产品目标 gate 失败且不读取点击 |
| 交付受众 Sybil/重放 | 同一 headless client、预取器或 push token 对探索内容生成一百万次成功 delivery | frame 按 eligible audience unit×content/surface×window×channel 去重并执行 invalid-traffic/replay cap；raw deliveries 可为一百万，unique eligible reach 至多一且 unknown/invalid 单列，不能据此宣称探索曝光兑现 |
| 触达身份单位错称 | 一个自然人用 100 个分别验证的账号/设备接收同一内容，另有 100 人共享一个机构 token；全部 delivery 均非 bot、预取或重放 | frame、opportunity 与 reach claim 必须冻结并披露 audience_unit_type、identity_namespace、linkage method/version 和误合并/漏合并界；前者最多称 100 accounts/devices，后者最多称 1 token。无 person-level oracle 时禁止称 unique people/audience reach，跨 namespace unknown 进入区间 |
| 共享 outcome 虚增命中 | 50 个 candidate 都由同一工厂开工或同一数据集验证 | OutcomeUnit/OutcomeCluster/CandidateOutcomeLink 去重共享结果；指标按 cluster 计算唯一 outcome coverage、n_eff 与稳健区间，不能记 50 次独立成功 |
| OutcomeFrame 候选后定制 | cohort 已产生候选，第 6 天按候选命题定制完整隐藏 frame，第 7 天前冻结且 frame 内无漏项 | frame 必须绑定协议并早于 cohort/首次 candidate 数据访问锚定，transitive candidate/selection/delivery lineage count=0；候选后创建即阻断 recall/capability，即使 generation terminals 完整 |
| 自我实现的预测命中 | 系统向用户提示冷门供应商，用户因提醒签约，30 天后把该采购行动链接为候选的现实验证 | CandidateOutcomeLink 标 exposed/possibly_exposed，并从纯提前发现指标排除或纳入最坏—最好界；只有预注册 shadow/holdout 或能证明 outcome actor 未暴露的结果可支持被动发现能力，干预效果单列 |
| 多行动者暴露择取 | 同一采购 outcome 中，收到提醒并发起行动的决策者 A 为 exposed，未收到提醒的签字人 B 为 unexposed；实现只选 B 写一条完整 assessment | OutcomeFrame 的行动者生成规则必须为 A/B 分别物化 OutcomeActorExposureUnit 与唯一 decision；actor units、terminals、delivery/publication lineage 和 link aggregation 四方相等。任一可归因行动者 exposed 则 link=exposed，任一缺失/不确定则 unknown/possibly_exposed，不能任选代表行动者洗白 |
| 验证证据选择性遗漏 | EvaluationCorpusSnapshot 含 1 份独立支持与 9 份协议合格反证，实现只把支持项写入 validation 数组 | 为全部潜在 EvidenceUnit 物化 ValidationEvidenceEligibilityUnit/Decision；include-support/include-counterevidence/exclude/failed 与 EvaluationResult、evidence package 和排除清单完全相等，漏反证或自由数组阻断能力声明 |
| 系统诱导验证 | 已注册记者收到候选通知后才调查并发布新谱系、新测量证据；该来源未被 candidate 招募 | 为全部 producer/investigator/operator 物化 ValidationEvidenceProducerExposureUnit/Decision；exposed/possibly_exposed/unknown/缺失只能标 system-induced validation/intervention echo，不能因新谱系或未走 RecruitmentCohort 计独立复现 |
| 评估 arm 输出漏账 | 系统与编辑基线都配置相同 corpus/cutoff/K=10，但保存系统全部 10 项，只保存基线最差 3 项并宣称胜出 | EvaluationArmManifest 展开各 arm GenerationUnit/Decision，揭盲前 OutputSnapshot 冻结完整 K 项；arm output members=EvaluationObligations=EvaluationResults，漏 7 项阻断比较能力声明和版本晋升 |
| PersonalScope 跨租户攻击 | 用户 B 直接 ID、重放 token、分页、导出、缓存、恢复或 provider callback 访问 A 的私有 canary | 所有私有对象/作业/缓存/备份复合绑定 scope+owner+authz epoch 与 RLS；B 不得获知存在性或内容，A 的私有 canary 不进入公共 event/log/model/report |
| 模型出站与跨阶段注入 | 网页及恶意 provider 输出要求读取记忆、修改 rights、调用 export/任意 URL，并夹带未授权片段 | egress proxy 实际字节与 OutboundPayloadManifest/PurposeAuthorization 完全相等；未列工具/网络/凭据和控制面写入均失败，tainted 输出只有 typed validation 后可作数据 |
| CDN/Range/stream 撤权 | 首个 body chunk 后提升 epoch，同时请求 CDN 离线命中、304、Range resume、SSE 重连和异步 export | 未建模模式默认拒绝；有限响应完整物化并绑定 token/head/epoch/payload，撤权后无新旧内容字节、旧缓存体或续传，只能失败、终止或重取 |
| 删除前备份回滚恢复 | 恢复含 canary 的 T0 备份，而真实撤权 checkpoint 在 T1；另回滚 checkpoint | RecoveryFence 在开放服务前取得最新独立单调 checkpoint、重放删除/销钥并验证 canary；checkpoint 回退或不可达时 deny-all，所有 blob/index/cache/report/export/provider retry 均不可恢复 canary |

### 15.3 上线阻断项

出现以下任一情况不得宣称“全球基础雷达 MVP 已通过”：

- 个人记忆或用户行为能改变全球候选输出；
- 转载数量被当作独立证据数量；
- endpoint/connector 的拆分、合并或迁移改变既有 `collection_opportunity` 分母、权重或历史覆盖率；
- PublisherAccount/OwnerGroup/SourceEndpoint 可变属性没有 Version/SourceRegistrySnapshot/`system_available_at`，或用后见收购、角色、rights、cadence 回写旧 edition 指标；
- 用 `source_declared_update_cadence` 直接生成执行分母，或通过降低 `planned_poll_cadence`、合并 slots、缩短游标或移除困难来源回写旧 `CollectionPlanManifest`，从而美化健康度；
- CollectionPlanManifest 不冻结确定性 opportunity ID 派生规则、不与物化机会表对账，或通过调度器宕机造成的机会缺行缩小采集完成分母；
- SourceDiscoveryProgramManifest 未在结果可见前冻结全部 frame opportunities，或只对已选择运行的 frame/已返回候选做完整性对账；
- 采集机会错过、排除或终止没有追加 CollectionOpportunityStateEvent，只靠可更新状态列或缺行表达 terminal state；
- 运行时从 `required_comparison_keys[]` 删除慢分层，或删 key 后仍把同一 global comparison scope 标为 normal；
- watermark、机会分母或历史 edition 只保存 `stratum_id` 而不冻结 `CoverageStratumVersion`，或用今天的纳入谓词回填旧结果；
- 来源级许可提示未经 record 级 RightsGrantVersion/AuthorizedContentScope/PurposeAuthorization 解析就传播到 `O_extract/O_model/O_train/O_signal/O_display/O_prevalence`；
- 用 EvidenceScope 充当采集、保存、展示或模型处理许可，allow 未用复合 FK 绑定同一 RightsGrantVersion/AuthorizedContentScope/确切 typed resource record，或未核对实际 byte/span/transform 上限；
- 把保存、展示或外部推理许可当作 training/fine-tuning 许可，`O_train` 非显式授权时默认 true，或无法追踪训练样本到 checkpoint/authorization epoch；
- 删除义务适用但模型不可验证 unlearn，仍继续使用受影响 checkpoint 且不销毁重训；
- 撤权后旧 `revocation_epoch` 在途任务仍持久化/展示输出，或发布提交未原子复核最新 epoch；
- 把最大 `system_available_at`、最后成功任务时间或当前时钟当作 processing watermark，或让旧数据晚处理跨过后续未完成输入推进 arrival frontier；
- 初始 item 不按 `item_first_seen_at`、`reportability=reportable|unknown` 的 revision 不按 `version_observed_at` 归属逻辑窗口，或用 `version_available_at` 改写逻辑归属；
- 没有唯一 ReportableArrival/ReportItemPlacement，导致同一 information arrival 在连续 edition、重试、补录或 amendment 中多次宣称 first publication；
- 改变既有时间线/作者语义的 `metadata_update` 被标为 non-reportable，或静默重排旧 edition；
- 缺失 `ClockPolicyManifest`、ClockHealthSnapshot 或 `clock_source_id/clock_skew_bound_ms/clock_health/ingest_sequence`，接受 worker 自报健康，或 `CLOCK_UNTRUSTED` 输入未隔离仍参与精确窗口、提前量或跨分层比较；
- 稳定身份行承载可变正文/成员，覆盖 immutable record/snapshot，或在登记为 `bitemporal_version_time` 的权威行存储/回写事后闭合字段而不是由 EventBase/SupersessionEvent 投影；
- 依据 `Version/Snapshot` 名称通配创建 stable parent、`system_from/valid_from` 或闭合字段，而不逐对象遵循 05 第 5.1/7.2 节 archetype；
- 给 EventBase subtype 再创建 subtype 专用第二事件身份，或让 typed event FK 不指向同一 `EventBase.event_id`；
- 采集断流期间仍生成衰退结论；
- 缺失只用一个空值表示；
- `baseline_status=baseline_unavailable|warming_up|coverage_shift` 的范围仍生成正式升温、衰退、流行度或“世界首次”结论；
- 把 domain/role unknown 当作内容质量失败、强制贴入现有 taxonomy、在 random_exploration 前静默丢弃，或未记录 `unclassified_eligibility` 与 selected/not-selected 分母；
- 合格未分类池足量时仍取消 `unclassified_open_world` 预注册子分层，或用低质、重复、无权/不安全内容填充其 provisional floor；
- 无法从展示内容追溯到原始来源、策略版本和选择原因；
- 合法删除或用途许可撤回后，当前摘要、信号、实体关系或卡片仍保留被撤销内容或可逆投影；
- 获准长期保存的 RawArtifact 没有 PreservationManifestVersion/events、独立副本/fixity 或通过恢复演练，仍宣称可形成十年档案；
- 损坏副本未隔离便进入分析，格式迁移覆盖原始字节，或 hash 算法迁移重写 artifact/版本身份；
- 备份、旧副本或被撤销密钥可以恢复已删除内容，或密钥轮换依赖未审计的明文旁路；
- RawArtifact `storage_mode` 字段组合违反联合类型约束，尤其 metadata_only 绑定正文、external_pointer 保存本地内容，或在 external_pointer artifact 原地更新可变验证时间/链接状态而不追加 ExternalPointerCheckEvent；
- 物理去重把相同字节的 RawArtifact provenance/rights/retention basis 合并，或把内容 hash 当法律身份；撤最后授权 binding 后仍保留可解密 blob；
- PreservationManifest/ArtifactBlobBinding 可变状态没有 Version/events，或最后 binding 删除与并发新增不是原子事务，产生悬空 binding、旧 key 复活或撤权访问窗口；
- 使用媒体/发布者永久“真相分”代替具体主张、版本和证据评估；
- 把 `dependency_unknown` 计入独立证据下界，或把可能独立上界表述为已确认独立证据；
- online p/e-value 只有边际校准，却未绑定 TestStatisticInputSnapshot、filtration、共享数据/依赖簇和抽样停止规则，仍用于统计确认或能力声明；
- Attention reach claim 未绑定明确 `audience_unit_type/identity_namespace/linkage_method_version`，或在没有 person-level oracle 与误差界时把账号、设备、token 数写成 unique people/audience reach；
- 多行动者 outcome 没有全量 OutcomeActorExposureUnit/Decision，允许任选未暴露代表人覆盖已暴露的因果行动者并计入纯预测命中；
- ValidationEvidenceEligibilityUnit/Decision 未覆盖 EvaluationCorpusSnapshot 的全部协议候选证据，允许自由选择支持项、漏反证或没有可审计排除终态；
- 验证证据缺少全量 ValidationEvidenceProducerExposureUnit/Decision，或把系统提醒诱导的调查、报道、测量标为 independent validation；
- EvaluationArmManifest/GenerationUnit/Decision/OutputSnapshot 缺失，或任一比较 arm 的 output members、EvaluationObligations、EvaluationResults 不相等；
- 非英语能力未经原文评测；
- 无法执行版权级联删除；
- 删除墓碑对低熵内容保留可公开枚举的裸 hash；
- 公开个人信息未经隐私分级就被长期保存、展示或传给外部模型；
- 固定快照不可复现；
- cutoff lag 超过单期 60 分钟仍标 normal，或用滚动 P95/准时率反向改写单期 `edition_status`；
- 用 configured cutoff、processing frontier 或“已选最新对象”单独充当实际截止点，而不计算 `data_cutoff=min(configured, required processing, selection completeness)`；
- ReportPipelineManifest 的 required keys 为空、由实际运行任务反推，漏掉 candidate generation/selection/claim stage，或 detector 未运行却以空候选集推动 selection completeness frontier；
- 把 preview/构建成功/PublicationAttempt 当成发布，首次事务缺少 fence/CAS/slot 唯一约束，或不同 idempotency key 产生多个 initial PublicationEvent；
- 首次 PublicationEvent/ReportEdition 与完整 ordered ReportItemPlacement/ReportCardPlacement 集合不在同一事务，缺 edition/event/slot 唯一约束或两套 deferred 一致性校验，允许先发布后补原始资讯/候选卡片；
- 首次成功后用第二个 PublicationEvent/ReportEdition 表达更正、覆盖旧版或重算首次 SLO，而不是以 expected-head CAS 原子追加 ReportAmendment/REPORT_AMENDMENT 与完整 placement delta；
- ReportItemPlacement 缺少 `presentation_event_id`，能引用非所属 edition 的事件，或 first-placement partial unique 冲突未回滚整个 publication/amendment；
- selected CandidateSelectionUnit 没有唯一 ReportCardPlacement，或 not-selected/failed unit 仍能生成卡片、卡片顺序与 edition 冻结清单不一致；
- required ClaimGenerationUnit/Decision 缺失、selected card/概览以零 claim 真空通过，或 ReportClaim 没有唯一 typed container/slot 决定；
- PresentationRenderPlan 未枚举最终标题、正文、caption、tooltip、alt/ARIA、通知和导出，最终输出与 content-unit/ref/hash 不能双向对账，或任何模型自由文本绕过 ReportClaim/source-text reference；
- candidate_count=0 的栏目用静态模板冒充“世界没有变化”，未生成绑定 completeness/watermark/coverage/rights/观测状态的 empty-state claim；
- ClaimExpressionVariant 缐失 required locale/channel/ARIA variant、无 translation lineage/equivalence，或改变否定、模态、数值/单位、来源归属与 AI 推断标记；
- ClaimCitation 允许无关 source title/quote 邻接为证据、缺 role/rights/scope，或用 nullable ClaimCitation 兼任无 claim 原始资料，而不是 XOR 的 RawSourceListingReference；
- REPORT_AMENDMENT 只保存 delta、当前读取并行拼 base 与多个 deltas，或没有 ComposedPresentationSnapshot/ReportViewToken 的完整 head 视图；
- 实时雷达没有稳定 RadarSurface/RadarPipelineManifest 与 RADAR_PUBLICATION expected-head CAS，允许预览/孤儿 GlobalRadarSnapshot 成为 current，或逐表读取“最新”而形成跨 snapshot 混合视图；
- 实时撤权只逐卡红删却保留旧排序，RadarViewToken 未绑定 head revision/snapshot/epoch/render-plan，或分页/缓存/详情能跨 epoch 拼接；
- RadarContinuation/详情/导出未把 token hash、snapshot、presentation event、query shape 与成员复合约束，允许 S2 token 读取 S1 card/cursor；
- 为完全漏发或合同失败创建任何 ReportEdition/PublicationEvent，而不是只保留 failed slot/state event 及任何实际发生的 attempts；
- 缺失预先冻结的 ReportScheduleManifest、未按确定性 slot IDs 对账，或通过整窗宕机造成的 slot 缺行缩小服务分母；
- 原地更新 ReportScheduleSlot 的状态字段，而不是由 PublicationEvent/ReportSlotStateEvent 生成 as-of 投影；
- ServiceSLOSnapshot 删除漏发或事后 cancelled slot、动态改变 quantile/时区/缺失规则，或未引用冻结的 `slo_config_version` 从而美化准时率；
- 探索配额被用来估计全球热度或讨论占比；
- 探索正常预算的集中度上限被用于截断流行度、局部快讯或重大事件溢出；
- feasibility spike 尚未完成却把本文任一 `provisional_target` 宣称为已验证能力或生产 SLO；
- 用“全球”“无偏”或“无权重”作为未经限定的产品承诺。

## 16. 策略变更与持续校准

所有配额、上限、分类、来源状态和算法版本都写入版本库。任何 coverage policy、`CoverageStratumVersion` 纳入谓词、`CollectionPlanManifest.planned_poll_cadence`/slot/cursor、`ReportScheduleManifest` recurrence/例外日、`RankingRuleManifest.required_comparison_keys[]`、connector/endpoint 映射、artifact/version 权利决策、用途资格、watermark/clock 方法、preservation policy（复制域、scrub、RPO/RTO、hash/key/格式迁移）、分类/聚类模型、SLO 或报告门禁的修改都必须产生新版本；不得原地覆盖已发布快照引用的配置。策略修改必须包含：

- 修改原因和证据；
- 受影响的历史指标；
- 受影响的 collection opportunities、content cursors、旧/新计划与 schedule cohorts、CoverageStratumVersion IDs、required comparison keys、rights snapshots/revocation epochs、用途集合和 processing watermark keys；
- 时间切片回测结果；
- 是否扩大或缩小某个群体的可见性；
- 新增的已知盲区；
- 对逻辑分母不变性、双时态/事件闭合、时钟隔离、artifact/blob 权利隔离、fixity/恢复、当前投影撤销、排名敏感性、normal/degraded edition 和 failed slot 门禁的迁移验证；
- 生效时间和回滚方案。

至少每季度复审覆盖矩阵，但不得为追逐短期新闻而频繁改动基础分类。季度审计优先回答：

1. 哪些地区、语言、角色和媒介持续欠债？
2. 哪些来源表面多样、实际属于同一所有权或转载谱系？
3. 哪条探索 `allocation_lane` 发现了后来增强的主题，还是只产生噪声？
4. 哪些“衰退”其实来自数据断流或平台规则改变？
5. 系统的公共覆盖策略是否正在形成新的结构性茧房？
6. 哪些高质量 domain/role unknown 候选获得了 `unclassified_open_world` 曝光，哪些持续未选，是否出现为降低 unknown rate 而强制归类的迹象？

本规范追求的不是一次性找到“完美权重”，而是让每一种权重、缺失、盲区和策略变化都能被看见、复现、质疑和修正。
