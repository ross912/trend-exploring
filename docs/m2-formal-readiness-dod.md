# M2 formal-readiness first slice

## INV-003 — claim/evidence scope binding

Executable DoD:

1. `external_world_state` 与 `source_claim` 必须带非空 `item_version_id`。
2. 每个 `evidence_scope_id` 必须有结构化 evidence-scope record。
3. 每个 evidence-scope record 的 `item_version_id` 必须等于 claim 的 `item_version_id`，且 record ID 集合必须与 claim 的 `evidence_scope_ids` 完全相等。
4. factual/source claim 只有在 `entailment_result=entailed` 时才可通过；`not_entailed`、无 evidence 或 scope 错配必须 fail closed。
5. `ai_inference` 不能借用 factual evidence 规则；它必须使用 `not_applicable` entailment、非空 premise scopes 和显式 `supported|unsupported` 状态。

Positive/negative fixture:

- `ruby -Ilib test/report_claim_contract_test.rb`
- positive: item version、evidence scope 与 `entailed` 完整绑定；
- negative: scope 属于另一 item version、缺结构化 item version、以及非 entailed factual claim。

实现位置：`lib/report_claim_contract.rb`；回归位置：`test/report_claim_contract_test.rb`。

## INV-004 — source conflict is disputed

Executable DoD:

1. A `SOURCE_CONFLICT` claim must retain `epistemic_status=disputed`.
2. The conflict record must reference at least two distinct source claims.
3. A conflict may not be accepted as `supported`/settled without the disputed state.

Positive/negative fixture：`ruby -Ilib test/report_claim_contract_test.rb` 中的双来源争议正例和 settled-state 反例。

## M2 phase-exit coverage slices

| ID | Executable DoD | Contract surface | Fixture assertion |
|---|---|---|---|
| COV-001 | prevalence lens 与 exploration lens 分离；缺少必需分层只返回 `QUOTA_INFEASIBLE`。 | `CoverageContract.allocate` | quota 正例与缺 strata 反例 |
| COV-007 | fixed/current ranking 同时输出，计算翻转率、top-K overlap 和冻结 tolerance reason code。 | `CoverageContract.compare_strata` | ranking shift fixture |
| COV-008 | 按 language 输出 discovery/processing P50/P95，并区分 `DISCOVERY_DELAY` 与 `PROCESSING_BACKFILL`。 | `CoverageContract.processing_delays` | late-language fixture |
| COV-011 | 欠配额分层生成 coverage debt identity、reason 和 rotation time，不静默删除。 | `CoverageContract.coverage_debt` | debt creation fixture |
| COV-012 | observation confidence 不改变 evidence confidence、prevalence 或 allocation。 | `CoverageContract.confidence_preserves_allocation` | C1/C3 contradiction fixture |
| COV-025 | domain/publisher role 为 unknown 时保留 unknown，进入 open-world random exploration，不改 prevalence。 | `CoverageContract.unknown_open_world` | unknown candidate fixture |
| COV-026 | 权威 debt 只持久化 `opened_at`；age 由 as-of query projection 计算，状态变化追加 event。 | `CoverageContract.coverage_debt` | ten-day query and immutable checksum fixture |
| LAN-002 | language × assertion_type 输出 false-support、abstention、coverage 和 Wilson CI；超阈值 fail closed。 | `LanguageEvaluationContract.evaluate` | threshold fixture |
| TIM-012 | nominal windows 连续；reportable arrival 恰有一个 first placement；metadata/non-reportable 不生成首发。 | `ReportPublicationContract.validate!` | contiguous windows and placement fixture |
| UX-001 | 关闭 AI 判断后仍保留标题、来源、时间、许可、证据和 coverage boundary。 | `PresentationContract.ai_judgment_disabled` | raw evidence visibility fixture |
| UX-002 | 无 rubric/oracle 返回 blocked；有 rubric 才输出 omission rate 与 CI。 | `PresentationContract.blind_review` | missing-oracle and positive fixture |
| UX-004 | 容量不足时输出 coverage debt/rotation，不以低质量内容补位。 | `PresentationContract.capacity_rotation` | quality-floor fixture |
| UX-006 | selection reason 必须可反查 signal types、lane、surface 和 reason codes。 | `PresentationContract.selection_reason` | human-readable trace fixture |
| UX-008 | AttentionBudget 固定 K/minutes、禁止 click/profile 输入、阻止探索项不可达和重复 delivery。 | `PresentationContract.attention_budget` | budget and reachability fixture |

这些 14 项构成 M2 的 phase-exit readiness scope。M2 的 release/normal-edition/service-claim 项（例如 INV-003、INV-004）属于后续 gate，不因 phase-exit readiness 自动宣称已完成；本轮已先落地 INV-003/004 的 contract slices。
