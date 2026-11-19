# 本机动态 ETF 目录与正式回测

这是可选的新数据源，不是替换 28 只 ETF 的清单，也不会安装或修改混合算法。**没有符合历史时点的原价、成交额、身份与行动审核，就没有正式结果。** 2026-11-19 的 109 方向观察文件只有名单和十日成交额（万元人民币）；不是每日成交额，更不是历史全市场。不要把其代表、分类或成交额回填。契约中的成交额直接来自逐日不复权源的人民币**元**字段，不用成交量乘收盘价估算。

## 增量启用，不动已有工作区

1. 在现有 `设计/workspace.json` 的 `strategies` **追加**策略声明，不要覆盖文件、页面、标签或已有五策略。例：`{"id":"ADAPTER_TEST","short":"适配","title":"契约冒烟测试","file":"策略/适配.js","history":20,"rebalance":"daily","requirements":{"contract":2,"screenHistory":3,"insufficient":"cash"}}`。把同目录的 `minimal.js` 放在该路径即可。它只是让一个合格标的产生测试订单，不是投资规则。
2. 可选 `requirements.config` 为 `设计` 内的相对 `.json` 路径。格式：`{"schema":"etf-strategy-config-1","versions":[{"known":"2024-12-02","effective":"2024-12-02","values":{"sampleLimit":8}}]}`。按 `(effective,known)` 严格排序；取两天都不晚于信号日的最后一版**整个** `values`，没有则 `{}`。日期应取真实可知日。JS、共用库、配置文件与整份设计一并封存。普通功能的 `输入/` 或 `records` 不参与正式策略。
3. 原子写 `请求.json`：`{"id":"design-01","operation":"reload"}`。前台 App 校验并启用设计；查看 `输出/请求状态.json` 的 ID 和状态。修改 JS 后再次用新 ID reload，不需重装。旧版本文件保存在 `版本/<workspace hash>/`。
4. 按 `market-format.md` 提供所需分区与审核材料；只交付缺的内容寻址原件。用 `{"id":"catalog-01","operation":"catalog","target":"<manifest SHA-256>"}` 核验并挂载到独立的「本机目录」。**不会切换旧本机行情指针**。目录挂载表示可读，不表示所有区间已通过覆盖检查。UI 在回测页选择「本机目录」和目标策略，查看区间或具体阻断原因。`全部策略` 仅运行与所选数据源兼容的策略。

## 正式 JS 契约

机器可读的输入、`screen` 返回、`run` 返回分别是 `strategy.schema.json#/$defs/input`、`screenResult`、`decision`。`run` 输出必须回显同一 `strategy/date`。跨字段约束由 Swift 额外检查：

- `screen(input)` 看到信号日已上市且未终止的全部目录成员，以及最近 `screenHistory` 日；不得返回重复或非 `eligible` 代码。未上市的产品不会泄露代码、名称或未来资格。`candidate` 是当时审核的基础资格，`eligible` 还要求独立预热达到 `history`。`state` 是**当天**状态，不是次日可成交承诺。停牌不虚构成交。`role/group/indexID` 来自历史分类，不从代码或名称猜测。
- `run(input)` 只看到 `screen` 返回的证券，窗口为 `history`（1–6000）。两次调用是不同的 QuickJS 上下文，不要在全局变量里传结果。`close` 是以可核起点原价为基准正向计算的调整信号，`turnover` 是元；两个数组和 `dates` 位置对齐，结束于 `date`。上市前是 `null`，已证停牌/无成交的成交额是 `0`。缺数据不是 `null` 或现金理由，会报错。
- `catalogVersion` 是当日可见代码及其上市日期、凭证的摘要；`metadataVersion` 是当日分类投影摘要；`marketVersion` 是该阶段证券输入投影摘要。**不把含未来行的整库指纹交给 JS**。实际结果在 `inputs` 中另存完整行情、目录、范围证据、设计、日历和执行版本。
- `selected`、`weights`、`scores`、`protection` 的证券必须在第二阶段集合；权重有限且非负，总和 ≤ 1（浮点容差 `1e-10`），余量现金。`protection` 省略即无保护标的；`exitDrawdown` 仅对显式保护生效。新模式不根据银行、路由名或固定策略 ID 推断行为。`waitReason` 由引擎填写，不是策略可伪造的错误豁免。
- `insufficient:"cash"` 下，空筛选分别记 `noListedProducts`、`noCandidates`、`listingWarmup` 或 `screenEmpty`，前一信号覆盖的账户交易日计一次。等待期间每日重新判断，恢复后按声明的换仓频率运行；持仓仍须真实卖出。`"error"` 则拒绝空集合。数据故障、未知资格、未核事件、超出交易日历和截断的已上市历史两种策略都不能绕过。
- `start` 是账户第一天。第一次选取在 `start` 的前一交易日收盘；`warmupFrom` 是使用的窗口起点，`firstSignal` 是首次非等待的有效策略判断，`firstTrade` 是实际首笔成交日，无成交时缺省。信号不保证成交。账簿继续采用原价、费用预算、整手、先卖后买、分红应收和分批可卖份额。新模式在除息日开盘交易前，以前一登记日结存确认权益，不会提前读取未来分区的公告。已核应收按到账日支付；退市/转换时持仓或挂单缺可执行结算条款则阻断，不按最后收盘价退出。
- 大目录先在短窗口 `screen`，再把小集合交给 `run`。仅 `minimumVariance(n,cov)` 限 3–28，输入为恰好 `n*n` 个有限数；不是目录上限。每次 VM 48 MiB、1.5 秒中断、结果 4 MiB；另有日期矩阵、单次输入预算。超限是错误，不缩短窗口或静默删证券。JS 必须只依赖输入；动态 VM 禁用 `Date` 和 `Math.random`。

## UI 与文件请求用同一正式引擎

`{"id":"replay-001","operation":"replay","target":"ADAPTER_TEST","fields":{"start":"2024-12-16","end":"2026-11-18","marketOrigin":"phone"}}`

日期只是请求示例，不代表已有这些历史。`phone` 对契约 2 指已挂载本机目录，对旧策略指原本机行情；`archive` 指当前已核导入快照。请求不修改显示中的策略、来源或日期。App 在前台处理，忙时不接第二个任务；一个请求占一个文件，勿用下一请求覆盖尚未受理的 ID。`输出/回测请求/<id>.json` 为专属回执，有 `id,digest,status,message,time,process` 及可选 `fraction,resultPath`。`accepted/running` **不是完成**；`done` 只在正式账簿持久化完成后写出，`resultPath` 相对研究工作区，其他终态为 `failed/cancelled/interrupted`。从 UI 暂停；未正常退出而保留的运行请求，下次前台处理同一请求时标记中断。使用新 ID、相同冻结输入和区间续算；同一 ID 不能用于不同内容。不要用 `run` 来请求回测。

每 21 个账户交易日和最后一日写原子检查点；新模式 ledger 4 验证账簿内容摘要和输入，旧模式继续 ledger 3，目录切换、代码或配置变化不能混续。旧结果和冻结版本不删除，可在 `数据/studies/v1/<指纹>/` 查看原始结果。`reload/run/strategy` 原入口保留。

## 构建与覆盖安装

在含 Xcode、iOS SDK 的 Mac 上运行 `swift test`，然后 `xcodebuild -project StockResearch.xcodeproj -scheme StockResearch -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`。设备归档可复用 `.github/scripts/build_ipa.py` 或仓库的「构建 iPhone IPA」工作流；`unsigned` 不能直接安装。Ad Hoc 使用现有签名团队、同一 App ID/Bundle ID、包含该设备的 profile 和匹配证书；工作流的 `IOS_P12_BASE64`、`IOS_P12_PASSWORD`、`IOS_PROFILE_BASE64` 用 Secrets，不写进仓库。按自己的发行流程递增 build number，再通过现有受信安装方式覆盖安装。**不卸载旧 App**。若签名/标识不匹配导致系统拒绝升级，先停止核对，不以删除容器、重新配对或复制整套资料解决。第一次升级底座需要安装，此后更换已支持的数据集合、参数和 JS 不需要签新 App。
