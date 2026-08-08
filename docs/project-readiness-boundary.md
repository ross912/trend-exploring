# Project readiness boundary after M4 phase-exit

这份边界记录避免把阶段门通过误报成最终产品落地。统计来自 `docs/04-acceptance-test-plan.md` 的 233 个验收定义。

## 已形成真实 evidence chain 的阶段门

| Phase | Formal phase-exit | 当前结果 |
|---|---:|---|
| M0 | 21 | 已通过既有 M0/M1 evidence chain |
| M1 | 9 | `fixture_passed=9/9` |
| M2 | 14 | `fixture_passed=14/14` |
| M3 | 21 | `fixture_passed=21/21` |
| M4 | 1 | `fixture_passed=1/1` |

M3 与 M4 的 phase-exit 只表示对应阶段的可执行基础能力完成，不覆盖同阶段的 release、capability-claim、service-claim、normal-edition 或 version-promotion gate。

## 尚未正式关闭的 gate

| 范围 | 未关闭数量 | 当前判定 | 主要缺口 |
|---|---:|---|---|
| M1 非 phase-exit | 42 | implementation_pending / evidence_pending | 生产服务身份、真实删除与 provider 回执、完整服务覆盖分母、并发/恢复闭环的 formal evidence |
| M2 非 phase-exit | 46 | implementation_pending / evidence_pending | 真实日报运行、端到端权限与撤权、服务 SLO 和 edition 运行数据 |
| M3 release | 18 | implementation_pending | live collection、真实来源谱系、并发 terminal、模型/时间投影和发布 UI 的完整 fixtures |
| M3 capability-claim | 31 | external_blocked | 隐藏来源与独立事件集、至少 13 周/12 个月可比观测、冻结 holdout、结果前评估协议与真实能力数据 |
| M3 version-promotion | 5 | external_blocked / environment_blocked | 真实 champion/challenger 运行、冻结未来窗口、模型供应商与生产晋升治理 |
| M4 release | 14 | external_blocked / environment_blocked | 生产认证与 RLS、私域 canary 删除、provider erasure、token signing/restore、真实跨租户服务身份 |
| M4 version-promotion | 1 | external_blocked | 个人数据隔离的训练/评价/晋升 lineage 与生产 challenger 管线 |
| M5 release | 10 | `fixture_passed=0`、`environment_blocked=10` | 实时雷达、生产模型与凭据、浏览器/表格 sink oracle、真实投递与运行 SLO |

合计还有 167 个非 phase-exit 定义未被 formal readiness 关闭。它们没有被手工改成 `fixture_passed`；在建立相应 coverage/evidence 前，不能宣称产品已最终落地。

## 当前真正的 blockers

1. production credentials、签名服务、production auth identity 和真实 connection pool 尚未提供。
2. provider API、远端删除 receipt、可信时间锚/WORM 和外部治理 quorum 不能在本地替代。
3. capability-claim 需要冻结的隐藏来源/独立留出集和真实前瞻数据；本地合成 fixture 不能证明真实能力。
4. M5 的实时运行、人工盲评和浏览器/电子表格安全 oracle 需要部署环境与人工复核。
5. 部分 domain schema、source frame 和服务 SLO 仍需产品/运营方冻结，属于 requirement/configuration blocker，而不是测试绿灯。

M5 本轮已完成本地 contract fixture（9 tests / 21 assertions）和 10 个 release gate 的 blocker artifact；这些 gate 尚未达到 release `fixture_passed`。

## Unblock 后顺序

先提供 production-safe disposable credentials、provider sandbox 和冻结 source/holdout manifest；再为 M1/M2 非 phase-exit 建立 evidence；随后闭环 M3 release/version-promotion、M3 capability claims、M4 privacy gates，最后才运行 M5 live radar release gates。每个 gate 仍必须有独立 fixture、artifact、运行时间和 blocker reason。
