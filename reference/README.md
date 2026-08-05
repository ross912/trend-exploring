# Reference catalog

本目录保存可供趋势探索项目借鉴的外部开源项目与组件评估。它不是 vendored source 目录；截至当前版本，没有复制任何第三方源代码。

## 文件

- `catalog.json`：机器可读的项目、组件、许可证、采用方式、目标模块和触发条件。
- `query.rb`：只依赖 Ruby 标准库的快速查询入口。
- 本文：人工采用路线与约束。

调研快照日期为 2026-08-05。stars、活跃度、许可证和项目状态会变化，实际采用前必须重新核验；目录中的判断不是永久背书，也不是法律意见。

## 快速查询

```bash
ruby reference/query.rb --priority now
ruby reference/query.rb --target M1.source_connectors
ruby reference/query.rb --category provenance
ruby reference/query.rb --license MIT
ruby reference/query.rb --project opencti
ruby reference/query.rb --search "continuation"
ruby reference/query.rb --priority later --json
```

没有任何过滤器时列出全部项目及组件。查询无结果时退出码为 1，便于脚本 fail closed。

## 当前采用路线

### 现在评估

| 组件 | 本项目目标 | 采用方式 | 结论 |
|---|---|---|---|
| NewsNow typed source adapters | M1 source connectors / registry | MIT，评估代码复用 | 优先用于第一个真实连接器，但逐来源另做权利审查 |
| Media Cloud queued ingestion | M1 collection / raw archive / watermarks | Apache-2.0，评估代码复用 | 优先研究 pipeline、RSS queue 与 HTML fixtures |
| OpenCTI provenance model | 跨阶段 provenance / evidence graph | CE 文件级许可核对后重实现 | 借鉴 primary source、relationship、confidence 的分层，不照搬 STIX 领域模型 |

### 下一阶段借鉴

| 组件 | 本项目目标 | 限制 |
|---|---|---|
| WorldMonitor source catalog/freshness | 来源可行性、健康状态、全球雷达 | AGPL，仅参考；覆盖目录不能按热度替代抽样框 |
| TrendRadar report/delivery/MCP | 双时段报告、通知和后续查询工具 | GPL，仅参考；禁止把兴趣筛选接入全球路径 |
| FreshRSS feed operations | RSS/WebSub/条件抓取 | AGPL，仅参考或评估独立服务 |
| MISP sightings/taxonomy/distribution | 观察、反证、taxonomy、rights | AGPL，仅参考；重复来源不算独立验证 |

### 后续算法基线

| 组件 | 本项目目标 | 约束 |
|---|---|---|
| Kats change-point/anomaly detectors | M3 非 LLM 弱信号基线 | 检测机会与阈值必须事前冻结 |
| OSSInsight velocity metrics | 增速、扩散、cohort comparison | 热度与探索曝光必须分开 |
| OpenNews graph prototype | 新闻到实体图的小型垂直切片 | 只作原型参考，不能据此声称生产成熟 |
| Auto-News LLM adapters | 多模型 shadow pipeline | 个人兴趣与笔记只能留在个人域 |
| Aleph document UX | 文档与实体探索 | 开源版本维护已 sunset，不建立新运行时依赖 |

## 强制边界

- 当前私有仓库尚未确定最终 LICENSE；GPL/AGPL 项目不得直接复制代码。
- MIT/Apache 2.0 只表示代码许可证相对宽松，不代表上游内容、网站条款、API 或个人数据可自由采集。
- 任何 source adapter 进入实现前都必须登记来源权利、观察边界、失败语义、更新节奏和保留策略。
- 个人兴趣、点击、长期记忆和画像不得进入全球采集、候选生成、排序或报告。
- 外部项目的 stars 只用于记录调研快照，不作为采用质量证据。
- 每次采用都要产生独立 implementation decision；本目录不能替代安全、许可证、数据保护和架构审查。
