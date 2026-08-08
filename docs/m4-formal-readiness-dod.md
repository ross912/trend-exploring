# M4 formal-readiness Definition of Done

M4 phase-exit `PRI-004` 完成条件：

- AI 随口假设先创建不可变 `MemoryCandidate`，状态为 `pending`。
- 候选包含个人域、正反证据、创建时间和 checksum；`personal_interpretation_eligible=false`。
- 只有用户明确确认，或已冻结版本的自动记忆规则接受后，才追加 `MemoryCandidateDecisionEvent` 并允许进入个人解释；拒绝仍保留候选和审计事件。
- 所有正例和负例由真实 fixture 执行，artifact 由 readiness recorder 生成并通过 checker 校验。

其余 M4 release/version-promotion 检查（PRI-001–003、PRI-005–013、INV-001–002）仍是独立 gate，不能由 PRI-004 自动覆盖。
