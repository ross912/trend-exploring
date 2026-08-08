# M3 formal-readiness Definition of Done

M3 的 phase-exit 只在以下条件同时满足时判定 ready：

1. `docs/04-acceptance-test-plan.md` 中 phase=`M3`、blocking=`phase-exit` 的 21 个 test code 全部出现在 `schema/m3-phase-exit-coverage.json`。
2. 每个 code 都有可定位的实现文件、针对该 code 的 fixture command、正例和负例；fixture command 实际退出码为 0。
3. 每个 evidence artifact 由 `scripts/record_m1_readiness_evidence.rb` 生成，包含 test code、精确命令、测试路径、执行时间、stdout SHA256 摘要和退出码；readiness checker 会重新校验这些字段。
4. readiness checker 的 `fixture_passed` 只来自真实 artifact，不信任 coverage JSON 中的人工状态字段。

## Phase-exit contract map

| Check ID | Executable DoD | Implementation / fixture |
|---|---|---|
| SIG-001 | 至少三种语言、三类独立行动者，并有可验证现实行动；signal types 含 emergence 与 diffusion。 | `SignalContract.emergence_diffusion` |
| SIG-005 | 每个本地行动者都有独立 evidence edge；不得以引用同一来源冒充独立采纳。 | `SignalContract.independent_actor_adoption` |
| SIG-006 | 两个 gold cluster 的预测 ID 与 gold ID 逐行一致；误合并直接失败。 | `SignalContract.separate_gold_clusters` |
| SIG-007 | mention 增长、负面/讽刺 stance 占多数、action stage 不变，并明确“关注增加不等于采用”。 | `SignalContract.stance_report` |
| SIG-008 | attention 增长但招聘/采购/部署/资本 action stage 不变；缺失 action evidence 显式输出。 | `SignalContract.action_stage` |
| SIG-010 | 消退/灭绝旧周期不改写；新独立行动追加 reactivated 周期。 | `SignalContract.reactivate` |
| SIG-012 | 仅有时间相关最多输出 observed_association；来源归因只能是 source_claimed_cause；不得输出 supported_mechanism。 | `SignalContract.causal_claim` |
| SIG-013 | 使用版本化同小时/星期/节假日/月末 baseline；在冻结阈值内不触发。 | `SignalContract.seasonal_anomaly` |
| SIG-014 | 概率检测器记录 tests_count、q_value 和 FDR；非概率检测器只记录 empirical false-alarm rate。 | `SignalContract.fdr_scan` |
| SIG-016 | 零分母、1→4 等低基数序列输出有限收缩估计和区间；只有真正独立样本可增加确认。 | `SignalContract.sparse_series` |
| SIG-017 | manifest FK 到具体 detector/version；同一 D05 key 的版本有独立 generation unit；manifest hash 可重算。 | `SignalContract.detector_manifest` |
| SIG-021 | 合格 unknown/OOD 项的 detector 全部 no-candidate，探索物化为 not-a-signal，不增加 candidate/prevalence 分母；不合格项不填位。 | `SignalContract.unknown_exploration` |
| SIG-024 | 100% CoverageItem 先有唯一 eligibility terminal；只有 eligible 后才创建 exploration unit。 | `SignalContract.exploration_eligibility` |
| SEL-001 | 一个候选可有多个 signal types，但恰有一个 allocation lane，surface sections 独立记录。 | `SelectionContract.multi_signal_allocation` |
| SEL-003 | 不可同时满足的多维配额返回 QUOTA_INFEASIBLE、缺口和约束；不静默重权。 | `SelectionContract.quota_infeasible` |
| SEL-004 | 预登记 2–3 个核心维度；Pareto 全同分时按稳定 candidate ID tie-break，并记录 reason code。 | `SelectionContract.pareto_tie_break` |
| ADV-001 | 域名数量不等于独立事实起点；同步、模板、引用链等信号使 sybil risk 升高。 | `AdversarialContract.sybil_risk` |
| ADV-004 | 没有 registry/原始记录时只能 unverified_claim，不能升级 confirmed_action。 | `AdversarialContract.unverifiable_action` |
| ADV-005 | 机器人协调传播保留为 manipulation_event；不得改写为自然公众支持，也不得静默删除传播事实。 | `AdversarialContract.manipulation_event` |
| MOD-003 | 闭源模型退役仍保留输入清单、输出工件、模型 ID、配置和证据；不虚构逐字节重算。 | `ModelContract.retire` |
| WRM-004 | 新来源/翻译能力造成历史断点时标 coverage_shift，分段或重置时间序列，不称为 concept novelty。 | `WarmingContract.history_break` |

## Boundary

本文件只声明 M3 phase-exit。M3 的 release、capability-claim、normal-edition、service-claim 和 version-promotion 检查仍是独立 gate；它们不能因为 phase-exit ready 自动变绿。
