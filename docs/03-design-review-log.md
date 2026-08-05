# 设计审查与收敛记录

- 项目：个人全球信息知识库
- 起始日期：2026-08-03
- 当前状态：M0 有条件冻结；M1 实施中（历史审查记录封存）

## 1. 审查目的

本记录用于证明规范经过了哪些反驳、修订和验证，而不是以“感觉已经完整”代替质量判断。

规范满足以下条件后才可冻结主版本：

1. 产品目标已转换为可测量代理；
2. 每项架构级不变量都有验收测试；
3. 每项评分特征都有数据缺失与操纵处理；
4. 历史回测明确防止未来信息泄漏；
5. 连续三轮独立审查没有发现新的缺陷类别；
6. 剩余限制被明确记录，而非被描述成已经解决。

## 2. 固定审查维度

每轮均检查以下维度：

- 需求一致性；
- 可测量性与验收性；
- 覆盖结构和隐含权重；
- 数据时间语义；
- 来源独立性与传播溯源；
- 统计基线、稀疏数据和冷启动；
- 生成模型幻觉与历史知识泄漏；
- 机器人、公关、审查制度和协同操纵；
- 版权、隐私、删除义务与安全；
- 个人记忆隔离；
- 成本、故障和长期可运维性；
- 用户界面的解释性与认知负担。

## 3. 第 0 轮：目标可实现性审查

### 新发现的缺陷类别

| 缺陷 | 影响 | 修订决定 |
|---|---|---|
| “全球所有信息”不可穷尽 | 无法定义完成度，容易把采集量误当覆盖度 | 改为分层覆盖矩阵、最低配额、集中度和缺口公开 |
| “完全无权重”不可能 | 来源选择和排序必然包含权重 | 改为不使用个人兴趣、系统权重公开、通道分榜 |
| 真正黑天鹅不可稳定预测 | 会诱导虚假精确和事后归因 | 改为探测弱信号、异常、扩散和现实行动变化 |
| 用户新颖度与记忆隔离存在张力 | 不读取个人记忆便无法在全球雷达中证明“对用户新颖” | 全球层衡量相对语料的新颖度；个人新颖度只在对话层说明 |
| “原始资料永不删除”与法律义务冲突 | 可能违反授权、隐私或删除要求 | 原始层追加式保存，但允许可审计的法务删除事件 |
| 单一重要性分数重新制造信息茧房 | 隐含权重不可见，热门内容吞噬弱信号 | 热点、增速、弱信号、衰退、扩散和探索分通道展示 |

### 本轮结论

已修订目标定义；进入覆盖与弱信号规范审查。本轮发现了新的独立缺陷类别，连续无新增轮数归零。

## 4. 第 1 轮：数据与时间语义审查

### 待验证问题

- 日报归属应使用来源发布时间、事件发生时间、首次发现时间还是抓取时间？
- 来源修改、删除或回填文章时如何生成版本？
- 迟到资料如何进入下一期且不静默改变历史报告？
- 同一消息的大量转载如何还原为传播链，而非独立证据？
- 不同平台不可比较的计数如何归一化？
- 来源整体失效时，系统如何避免把采集下降误判为讨论下降？

### 初步修订方向

初次内容使用 `item_first_seen_at`，后续版本使用 `version_observed_at/version_available_at`，派生对象使用 `system_available_at`。报告分别标记发现延迟、处理补录、纠错、撤稿与实质新增；所有趋势指标同时检查采集健康度和可观测分母。

### 本轮状态

已完成。新增修订：08:00/19:00 准时发布与处理到整点无法同时保证，报告必须公开 `data_cutoff`、分层处理水位、共同比较水位和正常/降级状态。本轮发现了新的独立缺陷类别，连续无新增轮数归零。

## 5. 第 2 轮：统计与对抗审查

### 新发现的缺陷类别

| 缺陷 | 影响 | 修订决定 |
|---|---|---|
| 分层探索样本被用于估计全球热度 | 过度采样的小地区或小语种会被误报为更流行 | 流行度镜头与探索镜头分离；前者保存分母和纳入概率，后者只负责扩大曝光 |
| 来源失联后从可观察分母消失 | 覆盖率可能在数据变差时虚假升高 | 拆分目标宇宙、合法可观察宇宙和实际成功采集集合，分别报告比率 |
| 抓取频率或来源数量变化制造趋势 | 数据管道变化被误认为世界变化 | 所有指标按活跃来源、采集机会和季节性归一，健康异常时熔断衰退结论 |
| 多份转载制造独立支持 | 公关稿和通讯社稿可伪造共识 | 建传播谱系、所有权图、行动者和测量独立性四类关系 |
| 讨论、支持、意向和行动混用 | 舆论扩散会被错误描述成现实采用 | 将 mention、stance、intent 和 action 分开抽取、统计和展示 |
| 低基数百分比爆炸 | 1 到 4 可被描述为 300% 强趋势 | 使用稀疏收缩、可信区间、最小谱系和单点异常独立通道 |
| 机器人操纵既可能是噪声也可能是事件 | 全删会错过政治变化，全收会伪造公众支持 | 自然扩散与操纵事件分通道，保留传播事实但不提升独立支持 |

### 本轮状态

已修订两份核心规范与验收测试。本轮发现了新的独立缺陷类别，连续无新增轮数归零。

## 6. 第 3 轮：回测与模型泄漏审查

状态：初审及第一轮整体交叉复核完成。

重点包括：

- 当前大模型的参数可能已经包含历史事件的未来结果，单靠提示词不能消除泄漏；
- 回测语料必须按当时的可用时间截断；
- 规则阈值不能在同一案例集上反复调优后再报告结果；
- 需要时间外验证集、负案例和当时未成为趋势的弱信号；
- “后来成功”不能倒推“当时应该被发现”。

已采用的控制包括：开发/验证/锁定时间段分离；现代模型历史回放只作诊断；上线首日起冻结前瞻台账；候选预登记反证和未来复核条件；以热门榜、分层随机和传统编辑作为盲测基线。

## 7. 第 4 轮：权限、治理与长期保存审查

状态：初审及第一轮整体交叉复核完成。

重点包括个人记忆服务权限、原始内容许可、删除与封存、密钥、备份恢复、模型供应商数据暴露和审计日志。

已采用的控制包括：独立存储与服务身份；记忆盲证据检索后再进行个人解释；来源许可分级；正文、分块、向量、缓存、派生引用和备份级联删除；外部内容无工具权限；恶意提示注入与 canary 记忆测试。

## 8. 第 5 轮：实现可执行性审查

### 新发现的缺陷类别

| 缺陷 | 影响 | 修订决定 |
|---|---|---|
| U/O/C 用 endpoint 个数作分母 | 拆一个 RSS 或合并一个 API 就能改变覆盖率 | 引入 connector、publisher/account、collection opportunity 和 content cursor；SLO 按计划机会与游标完整性计算 |
| 单一可观察集合覆盖所有用途 | 可抓元数据被误算成可全文分析、可送模型或可展示 | O_acquire 按计划采集机会建立；O_extract、O_model、O_signal、O_display、O_prevalence 再按各自 artifact/version 或传播观察单位建立 |
| 旧内容更新没有版本到达时间 | 新事实可能被漏报或回填到旧日报 | 增加 item、version 与派生对象三层系统时间和 revision type |
| 只截原文时间仍会泄漏未来派生知识 | 后来翻译、实体别名和聚类可进入过去回放 | 所有派生对象增加 bitemporal 字段与 system_available_at |
| 各语言使用不同完成水位做全局比较 | 慢语言与快语言被比较在不同长度窗口 | 跨层使用 comparison watermark；局部快讯不得进入全局排名 |
| 有引用被误当作证据支持 | 无关段落、自述、否定或单位错误仍可能发布为事实 | 增加 assertion type、EvidenceScope、语义蕴含与角色兼容门禁 |
| 30 天影子期验收 13 周/12 月基线 | 系统会伪造慢变量或永远无法通过 | 检测器按观测龄分阶段解锁，历史回填不计提前发现 |
| signal type、预算通道和展示分栏混名 | 同一候选可能重复消耗预算且排序不可复现 | 固定 signal_types、allocation_lane、surface_sections、ranking_rule_id |
| 不可变历史与合规删除冲突 | 旧摘要或模型输出可能继续泄露被删内容 | 分离非内容审计记录与可撤销内容投影，前瞻分母保留删失标记 |
| 历史回放模式含混 | 上线前档案被伪装成真实 `item_first_seen_at` | 区分 `prospective`、`operational_replay`、`archive_replay` 和 `retrospective_reanalysis` |
| 准时报告只有时间标签没有失败阈值 | 午夜 cutoff 的 08:00 报告也可能形式通过 | 冻结 publish latency、cutoff lag、完成度和 degraded edition SLO |
| 三份文档对象词汇不统一 | 不同工程角色会实现不同数据库 | 新增《统一数据、时间与决策契约》作为语义权威 |

### 本轮状态

已完成独立三方交叉审查，确认出现新的独立缺陷类别；规范正在按统一契约修订，连续无新增轮数归零。

## 9. 第 6 轮：修订后收敛审查

### 新发现的缺陷类别

| 缺陷 | 影响 | 修订决定 |
|---|---|---|
| 把处理水位定义为最大 `system_available_at` 或最后任务时间 | 慢管道刚处理完旧输入时，会被误判为已完整处理到当前时间，进而制造错误的跨语言热点与趋势 | 水位改为输入 `information_arrival_at` 的连续完成前沿，另存计算时间、scope、terminal states 与未闭合 gap；增加旧输入晚完成反例测试 |
| `O_acquire` 与下游处理目的共用 artifact/version 单位 | 来源机会、已捕获版本和展示投影可被错误地放进同一分母 | `O_acquire` 固定按计划采集机会；抽取、模型、信号、展示与流行度各按自身 artifact/version 或传播观察单位计算 |
| 规范对象仍混用稳定身份和内容快照 | 工程实现可能覆盖规范内容，无法重放旧去重与聚类结果 | 分离 `CanonicalItem` 稳定身份和 `CanonicalItemVersion` 不可变快照，并继续检查其他派生对象版本边界 |

### 本轮状态

发现了新的独立缺陷类别并已进入规范与验收修订，连续无新增轮数再次归零。修订后必须重新进行端到端时间流、处理目的权限、证据蕴含、冷启动、排序确定性和阻断门禁审查。

## 10. 第 7 轮：事件溯源、并发撤权与评价治理审查

### 新发现的缺陷类别

| 缺陷 | 最小失败方式 | 修订决定 |
|---|---|---|
| 不可变版本与事后填写 `system_to/valid_to` 冲突 | 计划→执行→取消时更新旧 action 行会改写历史，不更新又无法闭合区间 | 所有可修订对象分稳定身份和 Version；新增 Supersession/StateEvent，闭合时间由追加事件投影 |
| 系统时间没有可信来源 | 节点快慢、NTP 回拨或重启可让未来派生物进入过去查询 | 入口受控 UTC 时钟、偏移上界、clock health 和单调 ingest sequence；异常隔离并降级 |
| AI 推断与事实共用蕴含门禁 | 合理推断要么被错误阻断，要么被伪标为原文已证实 | 按 assertion type 分流：事实/来源主张做 entailment，AI 推断做 premise-support、反证和替代解释检查 |
| 权限检查与发布存在 TOCTOU | 模型任务获权后撤权，旧任务仍可完成并重新写回/发布 | 绑定 permission snapshot 与 revocation epoch；在途任务 taint/cancel，发布原子提交及读时投影再次检查 |
| 聚合 P95 与单期报告状态混合 | 多数报告很快时，个别陈旧数小时的 edition 仍可能被标 normal | 单期 cutoff hard max 决定 edition；滚动 P95/准时率只决定 service status；ReportEdition 保存权威发布事件和完整 SLO 字段 |
| 前瞻复核晚执行会偷看窗口后结果 | 第 7 天任务第 10 天跑，把第 9 天行动算成 7 日验证 | 每个 horizon 固定 outcome_as_of 与截止语料快照；协议/候选/结果写 hash chain 并锚定独立 WORM/可信时间戳 |
| 候选合并拆分可操纵评价分母 | 失败候选事后合并、成功候选保留多份即可美化命中率 | 首次冻结 candidate_id 与 proposition_family_id；生命周期映射不改 candidate 分母，同时报告两级结果 |
| 当前问题本身未纳入个人治理 | 病历号或秘密可经 neutral query 进入全局日志或未授权供应商 | neutralization 留在个人域，全球只收去标识临时查询；query/memory/correction 定义用途、保留、导出和级联删除 |
| 测试阶段继承机制不闭合 | M4/M5 可不跑早期删除/安全测试，M5 的 inherited 字段甚至未定义 | 新增 M0 契约自检、introduced-phase 自动继承、机器 applicability 和真实 M5 夹具；空测试清单失败 |

### 同轮 P1 收敛

新增统一 enum/reason registry 和跨文档 linter；采集 cadence 与 required comparison keys 进入 manifest；补语言×断言类型质量门槛；删除墓碑改用受控 HMAC/随机 receipt；独立验证必须与触发证据谱系独立；EvidenceUnit 扩展到依赖可追溯的独立调查；M0 provisional 与 M1 production SLO 版本分开。

### 本轮状态

发现多类新的独立失败类别，连续无新增轮数归零。当前文档进入第四轮定向修订，仍不冻结 M0。

## 11. 第 8 轮：可执行对象所有权与防逃逸审查

### 新发现的缺陷类别

| 缺陷 | 最小失败方式 | 修订决定 |
|---|---|---|
| Supersession 没有可执行双时间 payload | T3 才发现但 T2 已生效的修订，各实现对 T2/T3 查询给出不同结果 | 定义 EventBase、event system time、valid effective time、target/successor 与因果序列；system/valid 终点只作投影 |
| revision/reportability 判断可被原地改判 | unknown 次日改 non-reportable 时只能覆盖 RawItemVersion 或丢失更正时间 | 新增 RevisionAssessmentVersion；重分类用 decision available time 和 SupersessionEvent 追加判断更正 |
| `causal_claim` 可绕过两套门禁 | 只凭同期相关，把句子标 causal 既不做事实蕴含也不做 AI premise 检查 | 拆 source_causal_claim 与 ai_causal_inference；后者检查时序、混杂、机制和干预依据 |
| clock health 可自我声明 | 节点把允许 skew 配成 30 分钟仍称 trusted | 冻结 ClockPolicyManifest 的 quorum、5 秒 skew、TTL、holdover、回拨和恢复边界 |
| 报告对象无法表达漏发且 cutoff 可虚报 | 没生成 edition 时没有失败载体；只选到 06:00 却写 cutoff=07:59 | 拆 ScheduleSlot/Attempt/PublicationEvent/Edition；effective cutoff 取 configured、processing、selection 三前沿最小值 |
| 评价链可在揭盲后整体晚锚 | 第 8 天伪造一条内部自洽链仍可拿到有效时间戳 | 协议在 cohort 前锚定；candidate 五分钟 deadline；snapshot 截止 deadline；每项 inclusion proof 与 reveal time 必填 |
| Test applicability 可 fail-open | 把历史 P0 的 predicate 固定为 false 即可漏跑 | TestDefinition 签名；P0 predicate 永远 always；缺失/解析/验签错误一律 fail closed |
| 关键引用 ID 没有 owner object | evaluation snapshot ID 可实现为第 10 天重跑查询，仍表面满足有 ID | 增加 Rights/Scope/Watermark/PropositionFamily/EvaluationSnapshot/Publication/Correction 等 canonical 对象和 FK |
| preservation 与 blob binding 自身可变 | scrub、key rotation、repair、binding revoke 只能覆盖当前行 | 使用 Manifest/Binding Version 与专用事件；最后绑定删除采用 serializable/fenced 事务 |
| candidate 仍可重复发射 | 重叠窗口或 detector 小版本每天生成新 ID 并重复计算成功 | 冻结 proposition-family emission key；重试与小版本只追加 evidence/state event |
| storage pointer 条件不明确 | metadata-only 对象被错误要求正文 checksum/key，或外链被宣称可恢复 | 冻结四种 storage_mode 判别联合类型和分支级恢复 oracle |
| 物理去重与删除竞态 | 撤最后 binding 时并发新增合法 binding，可能误删或复活 key | RawArtifact 法律身份与 StorageBlob 分离，BindingVersion/epoch 原子处理并增加并发夹具 |

### 本轮状态

仍发现新的独立失败类别，连续无新增轮数归零。第四轮定向修订已将上述约束写入统一契约、路线和验收计划；需要在两份领域规范同步完成后重新审查。

### 集成复核补充

领域规范同步期间又发现三类实现逃逸方式，因此仍属于“有新增”，不能开始连续计数：

| 缺陷 | 最小失败方式 | 修订决定 |
|---|---|---|
| 只依赖已创建的报告 slot 形成 SLO 分母 | 服务整期宕机时连 slot 都没建，漏发会从分母消失 | 增加窗口前冻结的 ReportScheduleManifest、确定性 slot 派生与缺行对账；slot 状态只由追加事件投影 |
| ContentCursor 被实现为可覆盖的当前位置 | reset、回退或 worker 竞态覆盖旧 token 后，无法审计分页缺口与重复抓取 | 分离稳定 ContentCursor 与不可变 ContentCursorCheckpoint，保存前序、原因和受控序列，并加入覆盖反例 |
| 断言与测试定义仍有无 owner 的机器字段 | `supported`/`entailed` 各自实现，或测试签名只存在于文档文本，linter 仍形式通过 | 冻结 entailment/inference/epistemic 枚举；增加 TestDefinition/Version、GlobalRadarSnapshot 与 CoverageDebt owner 对象 |

## 12. 第 9 轮：DDL 可生成性、分母完整性与治理不可降级审查

本轮不再以“概念是否存在”为判据，而是让独立实施者尝试从规范唯一生成表、外键、事务和 gate。审查发现 12 个 P0 与 2 个 P1，连续无新增计数保持 `0/3`。

| 级别 | 缺陷 | 最小失败方式 | 修订决定 |
|---|---|---|---|
| P0 | 依据 `*Version/*Snapshot` 后缀猜 schema | standalone snapshot 被强行添加稳定父 ID，普通不可变记录被错误添加双时间闭合 | 增加逐对象 archetype registry；stable identity、immutable record、immutable manifest、event subtype 四类显式登记 |
| P0 | EventBase 使用不可约束的裸多态引用 | actor、rule、target 或 successor 可指向不存在/错误类型的 UUID，同一事件还出现两个身份 | 增加 Object/Record identity registry、typed composite FK、EventTypeRegistryManifest；subtype 与 EventBase 共用同一 event_id |
| P0 | 布尔 rights allow 无法表达部分授权 | 获准内部全文处理被当成可展示全文、可翻译、可 embedding 或可永久保留 | 分离 RightsGrantVersion、AuthorizedContentScope 与 PurposeAuthorization；每次处理/渲染原子复核 span、bytes、transform、derivative、processor、retention 与 epoch |
| P0 | external pointer 把链路健康写回原始工件 | 200→404→200 只能覆盖 last_verified/status，历史不可重放 | RawArtifact 只留捕获时 URI/provider key；每次可达性检查追加 ExternalPointerCheckEvent |
| P0 | 空 detector 集合可真空通过完整性门禁 | detector 整期没运行，却因“所有零个候选都有选择决定”生成 normal 空报告 | 冻结非空 ReportPipelineManifest；每个 eligible item×detector 必须有 CandidateGenerationDecision，缺行形成 WatermarkGap |
| P0 | 并发 worker 可各自发布初始版 | 不同 idempotency key 同时通过先查后写，各生成一份成功 edition | slot fence + CAS + 数据库唯一约束只允许一个 PublicationEvent；后续更正走 ReportAmendment |
| P0 | 首发、重试与补录没有稳定归属 | 同一资料在两期都被称为首次出现，或错过窗口后无法指向原名义期 | 增加 ReportableArrival 与 ReportItemPlacement，并对 first placement 作 partial unique、补录引用原 slot |
| P0 | 测试定义混入执行结果 | 第二次运行覆盖第一次 pass/fail，gate 可择优挑结果 | 分离 TestDefinitionVersion、TestCatalogManifest、TestRun、TestResult 与 GateDecision，闭合全量 FK/hash |
| P0 | 合法签名可掩护测试降级 | 攻击者用有效 key 把 P0 改 P1、后移阶段、缩小 fixture 或令 oracle 恒真 | TestGovernancePolicy 冻结 trust root/quorum 与语义 floor；ApprovalDecision 生效前旧强版本继续阻断 |
| P0 | 旧阶段阻断测试可在后续阶段失效 | M5 忽略 M1 的删除/覆盖回归，因为测试最初阶段已退出 | blocking 默认从 introduced phase 起适用于所有未来同类 gate；未知 applicability 和空目录 fail closed |
| P0 | 翻译在 M2 被使用、测试却到 M3 才引入 | M2 日报可读取未来译文而没有阻断测试 | 将翻译 as-of 测试前移至 M2，并要求 TranslationArtifactVersion owner |
| P0 | 多个机器 ID 只有名称没有 owner/决定历史 | preservation policy、翻译、个人记忆接受/拒绝可被实现为可变字段或临时字符串 | 补 PreservationPolicyManifest、TranslationArtifact/Version、MemoryCandidateDecisionEvent 与 CorrectionProposalDecisionEvent |
| P1 | 来源描述 cadence 与执行 cadence 混名 | 修改来源“通常更新频率”即可改变计划机会分母 | SourceEndpointVersion 只保存 `source_declared_update_cadence`；执行唯一由 CollectionPlanManifest.`planned_poll_cadence` |
| P1 | canonical 名称与测试目录统计漂移 | 文档显示旧对象名或旧测试数，使交接者误判同步已完成 | identifier linter 与脚本计数成为冻结前门禁；README 只在全套校验后更新 |

### 集成复核新增

修订上述问题时又发现三个新的独立失败入口，因此仍不能开始连续计数：

| 缺陷 | 最小失败方式 | 修订决定 |
|---|---|---|
| 采集机会漏建可缩小健康分母 | 调度器整窗宕机，manifest 应有 12 次机会却只落 11 行，系统按现存行算 100% | opportunity ID 从冻结 manifest 确定性派生；漏行对账补建并以 COLLECTION_OPPORTUNITY_MISSED 进入原分母 |
| 开放世界未知项被分类器静默丢弃 | 高质量新现象因 domain/role 均 unknown 既不进已知格也不进探索 | 在 random exploration 内预留 `unclassified_open_world` 子分层；只放质量、权限、安全合格项，不用垃圾填配额 |
| 主观 outcome 没有冻结标注治理 | 评审看到系统分组后改标签，或只保存最终裁决，能力提升不可证 | 增加 AnnotationProtocolVersion、双盲双标、ReviewerQualification、EvaluationJudgment 与 AdjudicationDecision |

### 本轮状态

修订已进入 00、04、05，并正在同步 01、02；在跨文档 linter、DDL 生成反例和下一轮独立审查完成前，仍为 `0/3`，不得标记冻结。

## 13. 第 10 轮：全局身份、终态唯一性与跨版本污染审查

第 9 轮修订完成后，两名独立审查者分别尝试生成 SQL/事务约束和破坏弱信号评价。仍发现新的失败类别，连续计数再次保持 `0/3`。以下只记录此前规范尚不能阻断的类别；单纯术语同步不单独计数。

| 级别 | 新缺陷类别 | 最小失败方式 | 已落实修订 |
|---|---|---|---|
| P0 | Object、Record、Event 三个局部 ID 空间可碰撞 | 同一 UUID 同时成为 SourceEndpoint、ReportEdition 和 EventBase，各表局部 FK 仍通过 | 新增单一 GlobalIdentityRegistry；object/record/event 为互斥子类，kind registry、具体表与 event subtype 双向 deferred 闭合 |
| P0 | immutable record 可被事件引用却不在 Object registry | ExternalPointerCheckEvent 以 RawArtifact 为 aggregate 时 FK 无处可指 | EventBase aggregate 改为 typed GlobalIdentityRegistry FK，EventTypeDefinition 冻结允许 kind/type |
| P0 | 普通 immutable record 没有穷尽时间 profile | T3 新建的 EvidenceUnit/SignalEvidenceLink 在 T2 查询中无法被过滤 | archetype 与 time-profile 双 registry 逐对象一一对账；所有 record 至少有规范 system-availability time |
| P0 | candidate/selection 可写矛盾双终态 | 同一 item×detector 同时写 candidate/no-candidate，同一 candidate 同时 selected/unselected | 先确定性物化 CandidateGenerationUnit/CandidateSelectionUnit，再以 unit 唯一键限制一个 terminal decision |
| P0 | grant 与 scope 可跨资源拼接 | metadata-only Grant A 与全文 Scope B 被组合成 allow | AuthorizedContentScope 绑定 grant version 与 typed resource record；PurposeAuthorization 使用同四元组复合 FK |
| P0 | 水位用稳定 stratum ID 串用不同边界版本 | V1 水位被 V2 ReportPipelineManifest 当作完整前沿 | ProcessingWatermark 与 required pipeline key 权威键改为 `stratum_version_id`，并与 scope/coverage policy 对账 |
| P0 | 排他状态事件缺少 expected-head CAS | 两个域从同一 RightsGrant/Signal/slot 写相反 next state，各自都合法 | EventTypeDefinition 冻结 state family/semantics/transition；连续 revision、predecessor 与 aggregate+family CAS 决出唯一 winner |
| P0 | gap、记忆撤销、提议撤回和签名密钥撤销没有事件闭合 | 删除 WatermarkGap 行即可推进水位，或原地改 accepted/revoked status | 补 WATERMARK_GAP_STATE、SIGNING_KEY_STATE；MemoryDecision 增 revoke，CorrectionProposalDecision 墳 withdraw，全部走追加式状态机 |
| P0 | edition 与 placement 可部分提交 | PublicationEvent/Edition 已成功，进程在写 item placements 前崩溃 | initial Publication/Edition/完整有序 placements 同事务；集合 deferred 对账，first/edition 内 arrival/order 均唯一；amendment 用独立 expected-head 链 |
| P0 | detector 展示 key 可替代具体规则版本 | D05 规则改变但仍用同一 key，失败版本从 required pairs 消失 | DetectorManifest entry 必须 FK `detector_id/detector_version_id`；generation unit 绑定具体版本 |
| P0 | 后续证据可回写候选冻结检测集 | T+20 验证证据被追加进 detection universe，同时用于验证 | SignalCandidate 与初始 detection commitment 永久不变；后续触发只写 CandidateTriggerEvent，评价只读冻结 detection IDs |
| P1 | live confirmation 只检查新 ID | 同一 API 测量切成两个 EvidenceUnit ID 被称为独立复现 | live 与 horizon 共用谱系、行动者/行动、measurement/data-generation process 和时间增量独立性 oracle |
| P1 | 个人反馈可经离线训练间接改变全球雷达 | 固定配置隔离测试通过，但“我不知道”反馈使下一版 ranking rule 晋升 | 个人点击/记忆/对话/新颖反馈禁止进入全球训练、评价和版本晋升；新增跨版本 lineage canary gate |
| P1 | 外链并发观察与覆盖债务 age 投影不确定 | 404/200 并发时当前 link state 随实现变化；落库 age 与 as-of 计算冲突 | 冻结 pointer status/reducer/tie-break 与 degraded-time 规则；CoverageDebt 只存 opened_at，age 只投影 |

### 本轮状态

00–05 已同步上述修订；01 的 60 个领域情景、02 的 JSON 示例和 04 的 168 个规范测试已完成第一遍静态校验。由于本轮出现新类别，下一轮只能从 `0/3` 重新开始，不能把“已修复”计作无新增。

## 14. 第 11 轮：呈现完备性、实时线性化与状态机可编译性审查

本轮先由本地事务审查发现日报卡片/主张缺口，再由一名独立 reviewer 攻击实时 current view，修订后由 schema 与安全/呈现两名独立 reviewer 复查。最初尝试的运营、统计、隐私三路 reviewer 因账户额度在读取前失败，不算独立审查，也不计入连续轮次。三名实际完成的 reviewer 均发现新类别，因此连续无新增仍为 `0/3`。

| 级别 | 新缺陷类别 | 最小失败方式 | 已落实修订 |
|---|---|---|---|
| P0 | 候选卡片借用原始资讯 arrival/placement | 只来自 ObservationSeriesSnapshot 的 selected candidate 无法展示，或为卡片伪造 ReportableArrival | 分离 ReportCardPlacement 与 ReportItemPlacement；selected unit/card/order 单独复合对账 |
| P0 | claim 可跨卡、漏句或发布后补写 | Edition/placements 已提交，claim 后写；另一 candidate 的句子挂入当前卡 | ReportClaim 绑定 presentation event、typed container/order，与 Publication/Amendment 同事务 |
| P0 | claim 清单可零条真空通过且前端可旁路 | 卡片 claim IDs 为空仍通过集合相等；title/tooltip/alt 另拼未经门禁的推断 | ClaimGenerationUnit/Decision、min/max ordinal、PresentationRenderPlan/typed PresentationContentUnit 与最终 DOM/序列化 hash 双向闭合 |
| P0 | 实时雷达没有原子 current-head | worker R2 先发布，旧 R1 恢复后覆盖；客户端逐表读到跨 snapshot 排名 | RadarSurface/RadarPipelineManifest、完整 GlobalRadarSnapshot 与 RADAR_PUBLICATION expected-head CAS |
| P0 | 撤权可把实时响应撕成旧排序与新墓碑 | 请求读完排序后 epoch 增加，再逐卡红删 | 旧 epoch head 整体失效；首字节前 RadarViewToken 重验，完整新 snapshot 前返回 recomputing/unavailable |
| P0 | 有效 token 可越界读取旧 snapshot 成员 | S2 token 请求 S1 card/cursor/export selection | RadarContinuation 签名绑定 token hash/snapshot/event/query shape，详情/导出做复合 membership |
| P0 | 空栏目用静态模板冒充世界判断 | worker 未运行却显示“没有值得关注的信号” | candidate_count=0 激活 required empty-state claim，绑定 completeness/watermark/coverage/rights/观测四态 |
| P1 | amendment 写入原子但当前读仍可拼裂 | base A/B，连续 amendment 删除 A、替换 B，读到 A+旧 B+新 B | 每个 initial/amendment head 物化完整 ComposedPresentationSnapshot，ReportViewToken 只读单一 committed head |
| P1 | locale/channel/ARIA 只有 hash、无语义闭合 | 英文或屏幕阅读器版本删掉“可能”或改数值仍各自 hash 合法 | ClaimExpressionVariant 绑定翻译工件和 semantic-equivalence，保留否定、模态、归属、数值/单位与推断标记 |
| P1 | 合法但无关来源可邻接成“证据” | claim A 旁放 source B 的合法 title/quote 并标 supports | ClaimCitation 绑定 exact source/scope/rights/citation role；只有 entails/source-asserts 可用支持标签 |
| P0 | claim slot min/max 无法生成唯一 units | min=2/max=3 却无 ordinal，第二条必撞 unit ID | deterministic key 加 presentation event、typed container、schema owner/hash、slot key 与 ordinal |
| P0 | render graph 仍有裸多态与双 plan | claim_ref 指 EvidenceUnit、跨 event ref 或同 event 两个 render plan | plan/event 唯一、unit/plan/order 复合键、typed container 与互斥 kind-specific 1:1 child |
| P0 | RADAR 首发 previous snapshot 约束自相矛盾 | revision=1 同时要求 previous 必填与 predecessor 为空 | revision=1 predecessor/previous 均空；后续均非空且 previous 等于 predecessor snapshot/surface |
| P0 | 同 epoch cutoff 回退规则矛盾 | degraded snapshot 的 cutoff=09:00 可按一段文字通过、按另一段拒绝 | 同 epoch 所有 frontiers/cutoff 不得倒退；不可比较变化只走新 scope/method epoch+COVERAGE_SHIFT |
| P0 | 状态机只有自然语言、不能生成非法转换门禁 | revision 连续但 SIGNAL candidate→established 仍可插入 | EventStateDefinition/TransitionDefinition 签名 children、完整首版 pair、typed guard FK/trigger |
| P0 | typed event API 名可能成为第二身份 | RadarPublicationEvent.radar_publication_event_id 与 EventBase.event_id 各自存在 | EventApiAlias 机器映射，API alias 强制等于同一 EventBase.event_id |
| P1 | 正式对象/字段仍有 shorthand 漂移 | ContentUnit、snapshot_status 与 canonical 名并存，linter 无法唯一解析 | 统一 PresentationContentUnit、radar_snapshot_status 等正式名并加入 CTR mutation |

修订后静态检查通过：02 的 6 个 JSON blocks 可解析；Markdown table 宽度一致；05 的 88 个 immutable records 与 time profiles 双向对账为 missing/extra/duplicate 全零；04 现有 177 个测试 ID 无重复。上述只是结构静态通过，不是一次“无新增”审查。

### 本轮状态

第 11 轮出现多类新失败类别，连续计数保持 `0/3`。第 12 轮必须从修订后的全文重新独立攻击，不能把本轮修复或静态通过计为 `1/3`。

## 15. 第 12 轮：分母身份、安全边界与连续评价审查

本轮由三名独立只读 reviewer 分别按 SQL/事务生成、安全/运营一致性、产品/统计/认识论攻击第 11 轮后的全文。三路均完成并发现此前未闭合的新类别：schema 2 个 P0，安全 4 个 P0，信号/评价 3 个 P0 与 2 个 P1。因此连续无新增仍为 `0/3`，不能把本轮修复计为收敛轮。

| 级别 | 新缺陷类别 | 最小失败方式 | 已落实修订 |
|---|---|---|---|
| P0 | CoverageItem 可同义复制并膨胀分母 | 同 scope/policy/input/strata 仅换随机 ID，生成 100 个 generation units | canonical projection key、UUIDv5、完整唯一键、manifest projection role 与 WatermarkGap 对账 |
| P0 | EventCausalParent 不是不可变 DAG | 自环、并发反向边、长环、晚 parent 或 T+1 给旧事件补边均能通过端点 FK | 复合主键、自环/时间/sequence/queue-proof、serializable/deferred DAG 门禁及 edge as-known 规则 |
| P0 | 私人域无可验证租户所有权 | 用户 B 以 A 的对象 ID、token、缓存、导出、恢复或 provider callback 读取/删除 A | PersonalScope/Version、owner+authz epoch 复合 FK/RLS/capability；PublicOnlyInputSnapshot 阻断私人 lineage 进入全球域 |
| P0 | 外部模型只有审计摘要、无 payload/能力边界 | 受限片段经派生文本外流，网页/provider 输出跨阶段驱动工具、URL 或控制面 | ModelTaskManifest、OutboundPayloadManifest、唯一 egress proxy、ModelInvocation receipt 与 tainted ModelOutputValidation |
| P0 | 撤权不能约束 CDN/Range/stream | 首 chunk 后撤权，旧 CDN、304、Range、SSE 或异步 export 继续交付 | DeliveryPolicyManifest、完整物化 PresentationDelivery、token/head/epoch/payload 绑定；未建模模式默认拒绝 |
| P0 | 旧备份可回滚删除/撤权高水位 | 恢复删除前备份时库内状态自洽，却缺少删除后的真实事件 | 独立单调 ComplianceRevocationLedgerCheckpoint 与生产开放前 RecoveryFence；回退/不可达时 deny-all |
| P0 | 连续自适应扫描每窗重置 FDR | 每小时动态生成主题并重置 BH，单窗 q 合法但全年假阳性失控 | SequentialHypothesisFamilyManifest/Ledger，所有 test/candidate/no-candidate/failed 入账，漏账阻断确认/晋升 |
| P0 | candidate 驱动来源招募伪造扩散 | C 触发招募 50 个新站点，后续转载被当成独立确认 | SourceDiscoveryDecision/RecruitmentCohort 保存 conditioning lineage；条件化来源不得确认触发者 |
| P0 | 共享 outcome 虚增有效样本量 | 50 个候选由同一工厂开工或同一数据集支持，被计作 50 次成功 | EvaluationObligation、OutcomeUnit/Cluster、CandidateOutcomeLink；按唯一 outcome、n_eff 与 cluster-robust interval 统计 |
| P1 | selected 不等于实际探索曝光 | 探索卡都在折叠区/第十页，热点占满首屏和通知 | AttentionBudgetManifest/AttentionPlacement 冻结 K、viewport/fold/page、通知与跨表面重复预算，不读取点击 |
| P1 | unknown/OOD 在 detector 前被吞掉 | 合格新领域材料因全部 detector=no-candidate 永远不可见 | PreDetectionExplorationUnit/Decision 与 ExplorationMaterialPlacement；显示为 not_a_signal 的未解释材料 |

上述修订已按 05→00/01/02→04 同步，并为每类新增独立机器 oracle。由于本轮本身发现新类别，下一轮仍从 `0/3` 开始；只有修订后全文的独立新攻击可以计为第 1 个无新增轮。

修订后静态检查通过：04 有 190 个唯一测试 ID、无重复且测试表均为六个数据列；05 有 108 个 immutable records，与 raw/bitemporal/snapshot/derived/operational time profiles 双向 missing/extra/duplicate 均为 0；02 的 6 个 JSON blocks 可解析；全部 Markdown 表宽与 code-fence parity 通过。这些结果只证明结构同步，不计为无新增审查。

## 16. 第 13 轮：机会分母、模型回调与能力声明审查

本轮由三名新的独立只读 reviewer 分别攻击 schema/DDL、安全/恢复、统计/产品。三路均发现新类别，经跨 reviewer 去重后共 10 个 P0 与 2 个 P1，因此连续无新增仍为 `0/3`。

| 级别 | 新缺陷类别 | 最小失败方式 | 已落实修订 |
|---|---|---|---|
| P0 | 检验机会在 ledger 前选择性消失或拆族 | 先评分只登记最小 p，或每个赢家新建 sibling family 各取 alpha | SequentialTestingUniverse、HypothesisTestOpportunity/Decision、root alpha 守恒与 scored=generated=ledger 对账 |
| P0 | 条件化来源跨 candidate/family 洗白 | C1 招募来源后这些来源触发 C2，因 ID 不同被当独立扩散 | ConditioningAncestryClosure 覆盖 candidate/family/query/cohort/source/CoverageItem/后继闭包 |
| P1 | detector 前探索资格分母可选择性缩小 | 100 个等质 no-candidate items 只为最吸引人的一个建 unit | 每 CoverageItem 的 EligibilityUnit/Decision 全量终态，缺项形成 gap |
| P1 | 可达 placement 被误称为实际曝光 | 探索页首屏 delivery=0，热点通知 delivery=10,000 | AttentionDeliveryOpportunity 与 placement/delivery 双向对账，严格区分 slot、delivered opportunity、reading |
| P0 | outcome coverage 没有独立现实结果分母 | 隐藏 frame 有 10 个结果，只给命中的 1 个建 OutcomeUnit，报告 100% | OutcomeFrameManifest、OutcomeGenerationUnit/Decision；coverage 读取 frame 全分母 |
| P0 | 多协议/指标/子群中只发布幸运声明 | 同一零效应 cohort 跑 20 个合法协议，只发显著者 | CapabilityClaimFamilyManifest/Unit/Decision 与 family-level multiplicity/sibling disclosure |
| P0 | EvaluationObligation 可有 snapshot/missed 和相反结果双终态 | 同一 obligation 同时写及时快照、missed 与两个正式结果 | EvaluationSnapshotDecision 与 EvaluationResult 分别 UNIQUE obligation，复合绑定同协议/horizon/ledger |
| P0 | 模型验证可并存 pass/fail 后择优 | 同一 output/schema/validator 写两个不同 validation IDs | ModelOutputValidationUnit/Decision，attempts 分离，required validators 全量唯一终态 |
| P0 | Delivery 可审计 A、实际交付 B | committed render=A，Delivery 自报 A+B 的自洽新 hash | PresentationRepresentation 冻结 expected bytes；Delivery hash/length 复合等于 committed representation |
| P0 | provider callback 可伪造、错绑或重放 | I1 callback 重放到 I2、改 body/nonce、并发第二终态或撤权后迟到 | ProviderCallbackReceipt 签名上下文、nonce/job+invocation 唯一、terminal CAS 与撤权依赖 |
| P0 | provider remote context 绕过出站字节 lineage | 公共 payload 只发送引用私人 session 的短 handle | ProviderContextSnapshot 递归 effective inputs/rights/private lineage/revocation set，公共任务 transitive private=0 |
| P0 | 单一 epoch 无法覆盖复合 payload | 同一导出依赖个人域和内容权利域，只撤其中一个仍可读 | RevocationDependencySnapshot 完整 `(domain,epoch)` set；任一 head 变化使上下游整体失效 |

修订已按 05→00/01/02→04 同步，并新增 SIG-022–024、GOV-013–015、ADV-009、UX-009、EVA-017–019、RTM-008 共 12 个测试。静态检查结果：04 有 202 个唯一测试 ID且无重复/列宽错误；05 有 126 个 immutable records，time-profile missing/extra/duplicate 均为 0；02 的 6 个 JSON 与全部 Markdown 表格通过。第 14 轮仍从 `0/3` 开始。

## 17. 第 14 轮：配置激活、响应边界与反事实污染审查

本轮由三名新的独立只读 reviewer 分别攻击 schema/DDL、安全/恢复、统计/产品。经与第 1–13 轮去重后，共确认 12 个 P0 与 2 个 P1；连续无新增仍为 `0/3`。

| 级别 | 新缺陷类别 | 最小失败方式 | 已落实修订 |
|---|---|---|---|
| P0 | online-FDR 可按当前统计量重排或分配阈值 | 机会全量入账且 wealth 守恒，但按 p 值排序并给小 p 更大 alpha | 数据可读前冻结 logical order、threshold reservation 与 predecessor information set；阈值仅由 history_<i 重算 |
| P1 | 来源发现阶段没有完整机会分母 | 目录有 1,000 个流，只为易接入的 10 个落准入决定 | SourceDiscoveryFrameManifest、Opportunity 与唯一 terminal，全分页 receipts 对账 |
| P0 | OutcomeFrame 可在看见候选后定制 | 候选出现后、结果揭盲前创建内部完整但有利的 frame | frame 绑定协议并在 cohort/首次 candidate access 前锚定，candidate-lineage count=0 |
| P0 | 系统输出因果制造“预测命中” | 用户收到提醒后采取行动，系统把该行动计作发现能力 | OutcomeInterventionExposureAssessment；纯预测只读 shadow/holdout 或 unexposed outcome |
| P1 | bot/prefetch/replay 膨胀 delivered opportunity | 单一 headless client 重放百万请求并全部 delivered | eligible audience×content×window×channel 去重，冻结 invalid-traffic policy/cap，raw 与 unique reach 分报 |
| P0 | body 正确但安全响应头可被替换 | 保持 body hash，删 private/Vary 或改可执行 MIME/inline | PresentationDeliveryEnvelope 原子冻结 status、完整安全头与 body hash |
| P0 | typed tainted 字段可成为 stored XSS/公式注入 | schema 合法 payload 经正常 render 在浏览器/表格执行 | PresentationSinkPolicyManifest 与逐 sink SafetyValidation，真实解析器零副作用 oracle |
| P0 | 非 callback provider 响应绕过 ingress receipt | sync/poll/download 直接创建 ModelOutputArtifact | 统一 ProviderResponseReceipt，所有模式共享 raw hash、复合 FK 与 terminal CAS |
| P0 | provider 远端删除没有可闭合状态机 | 本地撤权后只删主 file，thread/vector/cache 仍保留 | ProviderErasureObligation/Attempt/Decision、deadline、签名 receipt 与 post-delete verification |
| P0 | view/capability token 无独立密钥生命周期 | compromised 旧 key 新签 scope 正确 token 或跨类型复用 | TokenSigningKeyVersion、canonical envelope、type/audience/alg/jti/PoP 与撤销前置检查 |
| P0 | checkpoint authority root 可随备份回滚 | authority A→B 后恢复旧 manifest A，并在 A 内取“最新” head | 独立 ComplianceAuthorityEpochCheckpoint、old+new quorum transition chain 与外部 current pointer |
| P0 | manifest 配置可并发 split-brain | 同 scope 激活两个重叠 authoritative cadence manifest | ManifestSeries、typed ActivationDecision、expected-head CAS、revision/predecessor 与 range exclusion |
| P0 | standalone snapshot hash 自洽但成员语义错误 | as-of snapshot 同收旧新版本、只收失效版本或漏/增成员 | SnapshotMembershipProfile、typed unit/decision 与 child/terminal/selected/projection 四方集合相等 |
| P0 | TestRun 可通过重跑择优洗白 | 同 input 先 fail 后 pass，GateDecision 只引用 pass | GateEvaluation run slots/membership/closure；closure 前不决定、后不追加，全量结果结算 |

修订已按 05→00/01/02→04 同步，并新增 CTR-017–018、COV-027、GOV-016、ARC-009、SIG-025、ADV-010–011、PRI-008–009、UX-010、EVA-020–021、RTM-009 共 14 个测试。修订后的 schema 复核又校正了 activation 字段、snapshot subject profile 与 gate closure 的机器歧义；这是对本轮修复的完善，不另计新类别。静态检查结果：04 有 216 个唯一测试 ID；05 有 149 个 immutable records 与 31 个 manifests，time-profile missing/extra/duplicate 均为 0；02 的 6 个 JSON、全部 Markdown 表格与 code fences 通过。第 15 轮仍从 `0/3` 开始。

## 18. 第 15 轮：传输真实性、在线核销与条件有效性审查

本轮换用 schema compiler、真实协议/安全序列、统计反事实三路独立只读攻击。去重后确认 9 个 P0 与 2 个 P1，连续无新增仍为 `0/3`。

| 级别 | 新缺陷类别 | 最小失败方式 | 已落实修订 |
|---|---|---|---|
| P0 | provider receipt 的 mode child/真实性不闭合 | callback base 无签名 child，或 poll/download 伪造 DB-only transport identity | ProviderResponseModeProfile oneOf、callback 同 PK child IFF、captured exchange/mTLS/ingress attestation 与 terminal CAS |
| P0 | immutable ModelInvocation 前向引用未来 async output | pending invocation 无法插入，或靠 nullable FK 后续 UPDATE | 固定 Invocation←accepted Receipt←Output 方向；pending 先提交，完成事务零 UPDATE |
| P0 | token 合法复用与禁止 replay 冲突 | view 分页被全局 jti 核销误杀，single-use capability 并发双花 | TokenUsePolicyManifest 与 serializable TokenUseUnit/Decision；按 type/action 区分 single/multi-use |
| P0 | 自洽 envelope 本身可不安全 | 正常冻结 public-cache/可执行 MIME/危险 header，hash 全部相等 | EnvelopeSafetyValidation 绑定 audience/mode/policy/proxy，验证缓存、MIME、CSP/CORS 与 header-context/降级语义 |
| P0 | snapshot 可选用过期 membership profile | T3 snapshot 使用 T1 profile，内部四方集合仍自洽 | snapshot 复合绑定当时唯一 authoritative profile activation，stale/shadow/future 预先拒绝 |
| P0 | erasure 后迟到 provider job 重物化 | 删除/枚举已通过，排队 worker 后建 result/cache | ProviderErasureFence、generation high-water、producer cancel+drain、tombstone；新资源重开义务 |
| P0 | authority 轮换后旧 serving lease 仍在线有效 | 恢复时 A 最新，A→B 后隔离节点继续用 A lease 交付 | lease 绑定 authority epoch/root/head；pointer 切换原子失效旧 lease，首字节/cache/token 前重验 current root |
| P0 | online p/e 仅边际合法、对 filtration 条件失效 | p1=U、p2=1-U，阈值只看历史但 p2 条件不再 super-uniform | TestStatisticInputSnapshot、抽样/停止 lineage、dependence cluster 与 conditional-validity oracle |
| P1 | SourceDiscoveryFrame 上层批次可选择性消失 | 只为高准入的 10/100 地区语言格创建完整 frame | SourceDiscoveryProgramManifest、FrameOpportunity/Decision；漏 frame 也形成 gap |
| P0 | 多行动者 outcome 可挑未暴露代表洗白 | 决策者 A 暴露、签字人 B 未暴露，只记录 B | OutcomeActorExposureUnit/Decision 全行动者分母；任一 exposed 即 link exposed，缺失 fail closed |
| P1 | unique reach 未冻结现实统计单位 | 一人 100 账号或 100 人共享一 token，均非 bot/replay | audience_unit_type/namespace/linkage method 与 CI；无 person oracle 禁称 unique people |

修订已按 05→00/01/02→04 同步，并新增 CTR-019–020、COV-028、ARC-010、SIG-026、ADV-012、PRI-010–011、UX-011、EVA-022、RTM-010 共 11 个测试。静态检查结果：04 有 227 个唯一测试 ID；05 有 158 个 immutable records 与 34 个 manifests，archetype/time-profile missing/extra/duplicate 均为 0；02 的 6 个 JSON、全部 Markdown 表格与 code fences 通过。由于用户要求完成本轮后暂停，不启动第 16 轮；M0 仍未冻结，连续计数保持 `0/3`。

## 19. 第 16 轮：最终有界实施阻断审查

用户明确将本轮设为最终审查：只接受会阻止 M1 实施、导致未授权访问或使正式能力声明失效的 P0/P1；修复后不再重启无休止的发现循环。compiler、协议安全、统计产品三路经去重后确认 6 个 P0。

| 级别 | 最终阻断类别 | 最小失败方式 | 已落实修订 |
|---|---|---|---|
| P0 | provider 多页/分片/batch 成员可选择性遗漏 | 真实返回 A failed、B success，只保存 B 并忽略 A/next page | ProviderResponseSet/Profile、MemberUnit/Decision 与 expected=terminals=artifacts∪failures、continuation closure |
| P0 | single-use token 核销可随业务备份回滚 | J 已核销一次，恢复核销前备份后再次导出 | TokenUseLedgerCheckpoint 独立单调；恢复重放核销或推进 token-use/signing epoch |
| P0 | ServicePrincipalCredential 无可执行撤销生命周期 | C1 泄漏，轮换 C2 后 C1 仍通过 RLS/cache/egress | SERVICE_PRINCIPAL_CREDENTIAL_STATE expected-head、revocation domain、恢复 checkpoint 与逐请求 current-state 检查 |
| P0 | validation evidence 没有资格分母 | 快照有 1 支持+9 反证，只把支持写入结果 | ValidationEvidenceEligibilityUnit/Decision 与资格/终态/支持反证/协议 projection 四方相等 |
| P0 | 系统可因果制造“独立验证” | 收到候选提醒的记者据此调查并发布新证据 | ValidationEvidenceProducerExposureUnit/Decision；暴露/未知只能 system-induced/intervention echo |
| P0 | 比较 arm 可选择性漏输出/评价 | editor 输出 10 项，只落库最差 3 项后声称 system 更优 | EvaluationArmManifest/Generation/OutputSnapshot，arm outputs=obligations=snapshot decisions=results |

新增 ADV-013、PRI-012–013、EVA-023–025 共 6 个测试。最终静态检查：04 有 233 个唯一测试 ID；05 有 169 个 immutable records 与 36 个 manifests，archetype/time-profile missing/extra/duplicate 均为 0；02 的 6 个 JSON 与全部 Markdown 表格/code fences 通过。

本轮后按用户决策将 M0 标记为“有条件冻结的实施基线”：它不声称完美，也不满足旧的连续 `3/3` 无新增规则；冻结依据改为最终有界审查中的已知实施阻断项全部修复、机器 oracle 已登记。后续发现进入 M1 backlog，除非实际实现证明会造成数据破坏、越权或正式能力声明错误，否则不重新打开 M0 全面审查。

## 20. 尚不能消除的基本限制

以下限制只能被量化和公开，不能被彻底解决：

- 私域、封闭平台、删除内容和不可访问地区造成的观测盲区；
- 各地区数字化程度不同造成的可见性差异；
- 来源真实独立性和幕后协调关系无法总是确认；
- 低资源语言的翻译、分词和实体消歧质量较低；
- 新颖、异常与真正有长期意义并不等价；
- 现实世界反馈通常延迟，弱信号标签可能多年无法验证；
- 任何采集预算都意味着机会成本和隐含抽样偏差。

## 21. 冻结记录

2026-08-05：M0 有条件冻结并进入 M1。冻结基线为 README 与 docs/00–05、07 当前版本，验收目录 233 项；旧连续无新增计数停在 `0/3`，不再作为阶段退出条件。任何 M1 变更通过 manifest/version、测试和 implementation backlog 管理，不回写或伪称 M0 曾经完美。

## 22. M0/M1 综合自检一：基线状态与闭合并发

本节是实施期综合自检，不恢复旧的 Round 17 或连续 `3/3` 审查循环。检查范围覆盖 M0 文档契约、对象身份、验收目录与 M1 Ruby/JSON/SQL 工件之间的交叉一致性。

确认并修复两项实施阻断问题：

- M0 已有条件冻结，但 00/03/04 等文档页眉仍残留“草案/审查进行中”；现已统一为 M0 有条件冻结、M1 实施中的正式状态，历史轮次原文不回写。
- response set 追加路径与 closure 路径原先只检查各自事务可见的 closure 行，存在并发晚追加窗口；现统一锁定 `provider_response_set` 父行，使追加与闭合严格串行化，并把两个 `FOR UPDATE` guard 纳入验证器。

新增 `scripts/validate_project.rb` 作为统一入口，机器检查 233 个唯一验收 ID、41 个 stable identities、169 个 immutable records、36 个 manifests、记录 time-profile 双向穷尽、object map archetype/time-profile、6 个 JSON 示例、Markdown 表格/code fence，以及 JSON Schema/Ruby 字段集合。M1 静态结果为 19 个关键 SQL objects、11 个 guards、22 张表映射、17 tests/52 assertions 全通过。

真实 PostgreSQL parser/transaction 仍未在本机执行，因此本节不把 SQL 标为已可发布。已增加低配 Ubuntu 预检、空测试库保护、migration 与 catalog smoke 入口；下一步在获授权的云服务器上执行。
