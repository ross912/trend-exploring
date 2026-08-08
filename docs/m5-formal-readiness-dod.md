# M5 formal-readiness Definition of Done

M5 的 10 个 release gate 是 `RTM-001`–`RTM-010`。本轮先实现本地可执行的 contract fixture，但不把它们当作生产 release 通过：

| ID | 本地 contract | 完整 release 所需外部条件 | 当前状态 |
|---|---|---|---|
| RTM-001 | 快慢语言层、comparison watermark、frontier 与展示延迟 | 实时双语言采集和生产水位 | environment_blocked |
| RTM-002 | 固定 snapshot/seed 的确定性输出与 personal-read=0 | 30 分钟生产 Radar、auth/RLS 审计 | environment_blocked |
| RTM-003 | replay 去重、受控 sequence、cursor gap | 真实流连接、断线重连、持久化到达流水 | environment_blocked |
| RTM-004 | 单 winner、连续 revision、predecessor/head 约束 | RadarPipelineManifest、数据库并发/CAS、崩溃恢复 | environment_blocked |
| RTM-005 | revocation epoch 变化时只允许 recomputing/unavailable | 实时 delivery/cache/分页/详情交错撤权 | environment_blocked |
| RTM-006 | token、snapshot、surface、query shape、member membership 绑定 | production token service 与真实请求链 | environment_blocked |
| RTM-007 | 未建模 stream/range 默认拒绝，撤权禁止字节 | CDN、SSE/WebSocket、Range、304、异步 export 代理 | environment_blocked |
| RTM-008 | representation bytes/hash/length 确定性 | committed render 与真实 delivery 首字节门禁 | environment_blocked |
| RTM-009 | body 与安全 headers 原子一致 | 共享代理、浏览器和跨 audience cache 验证 | environment_blocked |
| RTM-010 | MIME、CSP、cache、CRLF header allowlist | H2→H1 proxy、浏览器执行/导航 oracle | environment_blocked |

本地 contract fixture：`ruby -Ilib test/m5_contracts_test.rb`，9 tests / 21 assertions，已通过。它只证明纯 contract 的失败闭环，不证明实时生产系统已经部署。

M5 readiness 的 10 个 artifact 使用 `environment_blocked`，没有任何项目被手工改成 `fixture_passed`。
