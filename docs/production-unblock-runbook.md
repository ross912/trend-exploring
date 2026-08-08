# Production unblock runbook

本地产品已经可以启动，但 M5 release gate 仍需外部/生产条件。下面是把当前 `environment_blocked` 逐项变成可验证结果的最短路径；任何一步没有真实输出都不能修改 coverage 状态。

## 必需输入

| 输入 | 用途 | 最小安全形态 |
|---|---|---|
| disposable PostgreSQL 15+ staging | snapshot/CAS、revocation、token-use 和 delivery 事务 | 私网监听、独立数据库、最小权限角色、可丢弃备份 |
| production-like auth/key service | RadarViewToken、audience、revocation epoch、rotation | staging key namespace，禁止把生产私钥放入仓库 |
| 两类持续 source stream | RTM-001/003 的快慢语言层、乱序、断线、gap | sandbox provider 或可回放录制流，保留原始 receipt |
| proxy/CDN/browser test lane | RTM-007/009/010 | 隔离测试域，覆盖 H2→H1、缓存、Range、SSE/WebSocket 和浏览器执行 oracle |
| RadarPipelineManifest + source/rights manifest | RTM-004/005 的 current-head 和 snapshot completeness | 签名、版本化、固定 method/scope/rights epoch |

## 执行顺序

1. 在 disposable staging 主机上运行 `bash scripts/cloud/preflight_ubuntu.sh`，确认资源和 PostgreSQL 版本。
2. 设置 `M1_DATABASE_URL` 与 `M1_CONFIRM_DISPOSABLE_DATABASE=YES`，运行 `bash scripts/cloud/verify_postgresql.sh`；不要对含用户数据的库执行。
3. 部署本地 vertical slice 的等价 runtime，并把 `LOCAL_PG*`、auth endpoint、provider sandbox、proxy profile 作为环境变量注入，不写入仓库。
4. 先运行：

   ```bash
   ruby -Ilib test/m5_staging_runtime_test.rb
   ruby -Ilib test/local_product_test.rb
   ruby scripts/local/smoke_radar.rb
   ```

5. 按 RTM-001→010 顺序执行真实 integration fixture。每项必须由 `scripts/record_m1_readiness_evidence.rb` 记录命令、退出码、stdout hash、运行时版本和时间戳；只有命令实际成功后才允许 `fixture_passed`。
6. 重新运行 `ruby scripts/report_m5_readiness.rb`，确认不存在 invalid artifact、missing test code 或 status mismatch；再复核 M0–M4 readiness。

## 不能通过替代品伪造的门

- provider/API credentials、签名服务、真实 connection pool、生产 auth identity；
- 真实 30 分钟实时 Radar 和持续来源水位；
- CDN/代理/browser 的执行安全 oracle；
- external governance quorum、人工审查和正式 release approval。

这些条件缺失时，正确状态仍是 `environment_blocked` 或 `external_blocked`，而不是 `fixture_passed`。
