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
