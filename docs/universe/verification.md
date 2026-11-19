# 动态 ETF 正式回测：核验记录（2026-11-19）

起点为 `dfd0ee42ddf6034152c59e7bb0ac18eb645cb99b`（包含 `v0.3.1` / `53b3951501359e18c4f6d345f18e92e308b5c974`）。以下三类证据用途不同，不能用合成行情证明历史收益或真机性能。

| 检查 | 实际结果 | 能证明什么 |
|---|---|---|
| Swift 6.0.3 / Linux x86-64，Debug | 原基线 20 项通过；修改后 32 项通过，0 失败，XCTest 9.415 秒 | 原有回归与 12 项新目录、执行、文件请求测试 |
| 旧模式真实离线对照，2026-01-19 至 2026-11-18 | 每个策略 201 个交易日；5 条资金曲线逐日到分一致，264 笔成交逐笔一致，4 种混合分支及检查点恢复通过，`issues: []` | 保留原 28 池、原策略和含费买单执行结果；不是新目录历史测算 |
| Python ETF 目录工具 | 34 项通过，0 失败 | 已有目录提取、单位、校验等工具回归 |
| 大目录小求解专项，单独启动 XCTest | 墙钟 1.96 秒；整个进程峰值 RSS 49,360 KiB | 120 只合成证券、12 个交易日输入和 8 个账户日；JS 选 3 只，调用 3×3 求解；计入造数、4 个非法求解调用和损坏原件测试，不是单次信号耗时 |
| App 源码 | `swiftc -frontend -parse App/*.swift` 通过 | 仅 Swift 语法，不是 Xcode 编译、签名、安装或真机验收 |

## 正式路径的合成验收

- 从独立本机目录和 Archive 分别核验同一批内容寻址原件。旧 28 池之外的 ETF 能进入两阶段 JS 和正式成交；删去暂存文件后仍能打开已核版本。修改本机 JS、重新激活后订单、工作区哈希和回测指纹均变化，旧检查点不能续入。
- 同一策略处理不同代码集合、数量、账户起点。专门让第二只 ETF 晚五个交易日上市：三日预热后，第一只在测试交易日序号 5 首次买入、第二只在序号 10 首次买入（从 0 编号）。不会为后者延迟前者，也不会让后者提前入池。
- 没有已上市产品、预热中、可选产品为空与缺原价、历史被截断、分类未知、公司行动不支持的处理不同。追加未来行情、证券和未来分类后，早期几个信号的权重及 JS 看到的目录、元数据、行情摘要不变；另测晚到参数不提前生效。
- 代表更换后卖单遇停牌仍保留；已登记分红形成应收，到账后清零。拆合待可卖份额延迟卖出；带持仓/挂单但无可靠退出条款的退市/转换阻断，不生成假想清算成交。
- 真实 QuickJS 执行入口测试超时、求解越界和无效数字；单证券采集测试使用注入的响应，不发联网请求。缓存命中、失败重试、取消恢复、原件损坏、账簿摘要篡改和文件请求 ID 均有覆盖。请求检查 `accepted → running → done`，并打开 `resultPath` 对应的持久结果；同名普通 action 不能代替正式回测。

## 复核命令

在仓库根目录、有对应依赖的环境执行：

```sh
swift test
python -m unittest discover -s tools/etf_catalog -p 'test_*.py'
swiftc -frontend -parse App/*.swift
```

本次 WSL2 使用已安装的 Swift 6.0.3、LAPACK/BLAS 和 OpenSSL 1.1.1；将该工具链的 `usr/bin` 放入 `PATH` 后，可复现本次运行方式：

```sh
swift test -j 5 --scratch-path /tmp/stock-dynamic-tests -Xcc -I/usr/local/openssl-1.1.1/include -Xlinker -L/usr/local/openssl-1.1.1/lib
/usr/bin/time -f 'elapsed=%e maxRSS_KiB=%M' /tmp/stock-dynamic-tests/debug/StockResearchPackageTests.xctest ResearchCoreTests.UniverseTests/testLargeUniverseSmallSolverAndBoundaries
/tmp/stock-dynamic-tests/debug/research-check --workspace-offline ../../research/fee_budget_fix_20261119/phone-parity-v1 /tmp/stock-dynamic-legacy-parity.json
```

最后一项需要本机原有的离线行情与独立对照文件，并非仓库自带数据。本次行情指纹 `2a29a563d0ebc0c52c2b893870b20f53660db8727bae9b54350f90f30b7a8dab`，工作区 `8587fe3844eaef0b5378267679b3dc07e528f1e830fcad906548e77e034b6353`；成交笔数依次为 `BANK_ELSE_GB` 115、`MOM20` 33、`MV` 36、`GB` 27、`SECTOR_M` 53。

## 尚未验证

未取得并审核 15 年逐证券的真实原价、逐日成交额、历史身份和行动完整性证据，未运行动态池长期实盘数据回测。109 方向文件不能补足这些数据。内容摘要验证不等于对上游提供者的独立背书，历史范围、声明和原件的真实性仍需核对。只支持契约中已定义的执行规则；没有实现可靠结算的事件必须阻断。未在 iOS SDK 或真实 iPhone 上验证构建、签名、升级保留数据、内存峰值或前台文件轮询；未部署、未触发远端构建、未替换本机行情或策略、未触发全量采集。
