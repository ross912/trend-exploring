# Codex × Kimi 中继协作协议

> 本文档由 Kimi 写入（2026-08-03），定义 Codex 与 Kimi 两个 Agent 在本项目中的分工与交接机制。
> Codex 阅读本文档后，即可按第 2、3 节格式向 Kimi 派发任务。

## 0. 角色定位

| | Codex | Kimi |
|---|---|---|
| 定位 | 工头 / 突击队 | 常驻后勤 / 哨兵 |
| 强项 | 编码、重构、规范实现、PR | 7×24 在线、定时任务、信息抓取、盯盘监控、报告生成、桌面通知、Dashboard 看板、长期记忆 |
| 工作方式 | 会话式，爆发式产出 | 持续在线，定时轮询，自动执行 |
| 不在线时 | 停摆 | 仍按调度运行 |

核心原则：**Codex 不等待 Kimi，Kimi 不打扰 Codex。** 双方通过文件中转站异步交接。

## 1. 总体机制：文件中转站

```
/Users/midongkeji/Documents/kimi/workspace/relay/
├── inbox/    ← Codex 写入任务单（每张单一个文件）
├── outbox/   ← Kimi 写入执行结果
└── archive/  ← 已完结任务单（由 Kimi 归档，保留审计轨迹）
```

流转过程：

1. Codex 干活过程中遇到需要"在线、定时、持久"的任务，按第 2 节格式写入 `inbox/`，随后继续自己的工作，不阻塞。
2. Kimi 侧挂有定时任务，定期扫描 `inbox/`（默认每 10–15 分钟），发现新单即认领执行。
3. 执行完成后，Kimi 将结果写入 `outbox/`，把任务单移入 `archive/` 并更新状态字段；如有需要，向用户推送桌面通知。
4. Codex 下次运行时读取 `outbox/` 中对应任务的结果，继续编排后续工作。

## 2. 任务单格式

任务单为单个 Markdown 文件，文件名即任务 ID：

```
inbox/20260804-001-source-health-check.md
```

文件内容使用 YAML frontmatter + 正文：

```markdown
---
id: 20260804-001
created_by: codex
created_at: 2026-08-04T09:00:00+08:00
type: monitor | fetch | report | notify | other
priority: normal | high
schedule: once | daily 09:00 | every 6h
status: pending        # pending → claimed → done | failed
result_ref:            # Kimi 完成后回填 outbox 路径
---

# 任务描述
用自然语言写清要做什么、验收标准是什么。

# 输入与约束
- 相关路径、URL、参数
- 禁止事项（如：不得修改 docs/ 下任何文件）
```

Kimi 认领后第一时间把 `status` 改为 `claimed` 并提交 git，避免重复执行。

## 3. 任务类型与路由

适合派给 Kimi 的任务：

- **monitor**：定时检查某个来源/接口/市场数据是否变化，变化时写结果并通知
- **fetch**：定时抓取指定 URL/数据源，原始内容落盘（对应本项目"原始资料层"）
- **report**：基于已有材料生成日报/周报（Markdown 或 PDF），输出到约定路径
- **notify**：到点提醒、截止前提醒、异常提醒（桌面通知）
- **other**：需要"一直在线"或"跨会话记忆"的任何杂活

不适合派给 Kimi、Codex 应自己完成的：代码实现与重构、规范文档的主体撰写、需要一次性深度推理的架构设计。

## 4. 状态流转与验收

- `pending`：Codex 已下单，Kimi 未认领
- `claimed`：Kimi 已认领，正在执行（此时 Codex 可假定任务会被处理）
- `done`：完成，`result_ref` 指向 `outbox/` 中的结果文件；Codex 负责验收，验收不通过可重新下单并在正文中引用原单
- `failed`：执行失败，正文末尾由 Kimi 追加失败原因与已尝试的补救；是否重试由 Codex 决定

所有状态变更伴随 git commit，commit message 格式：`relay: <id> <status>`。

## 5. 与本项目（个人全球信息知识库）的结合点

Kimi 的常驻特性恰好补本项目 M0 之后的空白：

- **来源健康监控**：对覆盖矩阵中的来源做定时可达性/断流检查，支撑"来源断流必须显式呈现"这一不变量
- **原始资料定时采集**：按覆盖矩阵定时抓取公开来源，原始快照落盘、只追加不覆盖，符合"原始与派生分层保存"
- **可行性试验执行**：M0 之后的"来源授权、语言质量、处理成本和报告时延"试验中，定时与成本测量类任务可由 Kimi 承担
- **报告时延压缩**：日报/信号摘要的定时生成与推送

注意：Kimi 产出的原始抓取与初筛结果**只进入原始资料层**，不直接写入派生分析层；信号评分、合并/拆分等判断仍由本项目规范流程完成，遵守 00–05 号文档的全部不变量。

## 6. 操作约定

- 双方都不得直接修改对方正在编辑的文件；交接只通过 `relay/` 目录和 git
- 任务单正文必须写明验收标准；无验收标准的单 Kimi 可标记 `failed` 并注明"验收标准缺失"
- Kimi 对 `docs/` 下文件只有读取权限（本协议除外）；Codex 对 `relay/outbox/` 只读
- 争议与协议修订：任何一方提出修订，写入本文件新章节并在 git commit 中说明，由用户裁定

## 7. 启用清单

- [x] 本协议写入 `docs/06`
- [ ] `relay/` 目录结构建立（inbox / outbox / archive）
- [ ] Kimi 侧定时任务上线（扫描 inbox）
- [ ] Codex 首次下单联调（建议用一张 notify 类测试单）
