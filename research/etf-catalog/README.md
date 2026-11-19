# 沪深 ETF 研究目录

**只看股票板块时，打开 [84 个板块的观察指数](equity-indices/2026-11-19/report.md)。** 每个板块一行，只列指数名称、代码和已映射产品数。需要看宽基、风格或境外市场时，再查 [全部 440 条股票指数记录](equity-indices/2026-11-19/indices.csv)。选定方向后，用 [基金映射表](equity-indices/2026-11-19/fund-map.csv) 查产品。债券 53 只、货币 27 只、黄金及商品 17 只在股票观察表中占零席，完整市场目录仍可用来匹配未来新上市产品。

**按板块挑一只**可直接查看 [84 个板块及各自的代表 ETF](sector-seats/2026-11-19/report.md)。这一视图把 748 只境内股票 ETF 压成 84 个板块席位，逐只保留专项备选。覆盖板块之外的宽基、风格、跨境和待核等产品沿用既有分组，全目录共 652 席。[代表表](sector-seats/2026-11-19/seats.csv) · [全部 1,722 只的映射](sector-seats/2026-11-19/members.csv)

2026 年 11 月 19 日观测到 **1,722 只**沪深上市交易证券。严格归组后有 **784 个候选**，比逐只评估减少 **938 个（54.47%）**。七项细分方向提案若全部采用，可进一步降到 **777 个**，共减少 **945 个（54.88%）**。407 只待核产品在两套方案中各自占一席。建议第二阶段先以 **784 个组**作为资料核查和研究范围，逐项接受风险后再决定是否使用 777 组方案。交易标的和同时持仓数量须另行确定。

[筛选报告](2026-11-19-c433b9a1b4f282ea/report.md) · [完整目录](2026-11-19-c433b9a1b4f282ea/catalog.json) · [主方向统计](2026-11-19-c433b9a1b4f282ea/directions.csv) · [逐只映射](2026-11-19-c433b9a1b4f282ea/members.csv) · [全部组与保留理由](2026-11-19-c433b9a1b4f282ea/groups.csv) · [待核清单](2026-11-19-c433b9a1b4f282ea/review.csv)

| 主资产 | 原 ETF | 严格归组 A | 方向提案 B | 待核 |
|---|---:|---:|---:|---:|
| 股票（含跨境） | 1,625 | 714 | 707 | 363 |
| 债券 | 53 | 26 | 26 | 0 |
| 黄金及商品 | 17 | 17 | 17 | 17 |
| 货币 | 27 | 27 | 27 | 27 |

## 名单依据

| 资料 | 取得与验证 | 用途 |
|---|---|---|
| 上交所基金列表 `FUND_LIST` | `fundType=00`，19 页 × 50 条，共 950 个唯一代码 | 交易代码、简称、管理人、上市日期、产品子类、标的代码和名称，含交易型货币基金 |
| 上交所基金网站综合表 | 1,263 行，13 页。按 ETF 类别树 `F1*` 筛出 950 个，逐代码与前表相符 | 独立核查上交所分类口径，排除 LOF、实时申赎货币基金及 REITs |
| 深交所 ETF 专表 `fund_etf` | 声明 772 行、78 页，服务端每页 10 行。请求 1,000 行仍只返回 10 行。XLSX 实得 772 个唯一代码，核对首页和末页，末页 2 行 | 交易代码、简称、拟合指数和管理人 |
| 深交所综合基金表 `1000_lf` | 1,088 行、55 页、每页 20 行，末页 8 行；整表中 772 个 ETF 与专表代码完全一致 | 上市日期、投资类别及管理人交叉检查 |
| 逐只基金档案 | 950 份上交所档案、772 份天天基金基本概况，均按代码核对 | 全称和产品属性。深市以专表提供的代码配合档案“跟踪标的”，保留原始字段 |
| 11 月 18 日深交所 PCF | 对 772 份原始 XML 核对文件名、内部证券代码、市场和日期。11 月 19 日专表与之逐只比较，代码和拟合指数均相符 | 额外核验深市成员与指数，不参与相似度或持仓重合率计算 |

深市 11 月 19 日两张官方报表通过交易所的公开 HTTP 下载地址取得，当时 HTTPS 连接中断。上交所列表未返回业务日期，目录保存观测日期。Excel 下载摘要、分页元数据、代码集合摘要和字段来源在目录顶层 `sources`、`markets`、`field_sources`。上海的交易型货币产品按交易所二级市场产品口径纳入。当前目录以交易代码计数，多份额共用一个交易代码的产品只占一个证券名额。例如易方达保证金货币 A/B 共用 159001 交易。披露检索库可以含待上市、非独立交易份额及过往产品，不能直接用作在市名单。[上交所基金列表](https://www.sse.com.cn/assortment/fund/list/) · [上交所基金档案](https://etf.sse.com.cn/fundlist/) · [深交所 ETF 列表](https://fund.szse.cn/marketdata/etf/index.html) · [深交所基金列表](https://fund.szse.cn/marketdata/fundslist/index.html) · [天天基金档案示例](https://fundf10.eastmoney.com/jbgk_159919.html) · [管理人份额说明](https://static.cninfo.com.cn/finalpage/2026-02-12/1224978012.PDF)

PCF 验证读取归档中的深市 XML，并抽查了 159919 的交易所原件，两者 SHA-256 相同。归档地址、散列和当天专表的独立观测在证据文件中。可用 `verify-pcf` 对归档复核。[11 月 18 日证据](evidence/szse-20261118.json) · [当日归档](https://github.com/y1han/china_etf_pcf/releases/tag/20261118) · [深交所原件](https://reportdocs.static.szse.cn/files/text/ETFDown/pcf_159919_20261118.xml)

巨潮披露检索把 809 个代码标为 ETF，其中包括本目录全部 772 只深市证券。另 37 个检索代码留在差异清单，逐只状态须另查公告。[巨潮代码差异](evidence/cninfo-20261119.json)

## 分类、分组与实际差异

层级为资产、地区、行业或方向、细分暴露与风格、标的指数和证券。附加标签可多选。主方向、A 组、B 组各自只有一个 ID。名称规则可以提示行业，进入严格组还需同时满足代码、规范标的名、境内市场和被动产品机制条件。上交所和深交所代码表达不同的已核实别名按配置处理。未经确认的同代码异名、市场或产品机制不清、非标准跟踪及跨境对冲资料不足均保留独立候选。[规则与指数资料](../../tools/etf_catalog/rules.json)

全部 1,722 只均有代码、管理人、全称及上市日期。1,600 只符合指数识别口径（92.92%），即同时具备可识别的正式标的名称、指数代码且无未决冲突。该口径的分母包括货币及黄金产品。1,717 只具有主资产、市场和方向（99.71%）。5 只的市场归属需要补证。分类覆盖和严格合并资格分开计算。当前资料可按品牌辨认 1,324 只的指数发布机构，其他标为未知。场内交易币种、基金本位币和标的汇率敞口分别记录，跨境基金仍需逐只查阅合同的对冲及复制条款。

| 实际产品 | 处理 | 暴露或产品差异 |
|---|---|---|
| 华泰柏瑞沪深300 510300、嘉实沪深300 159919、国泰沪深300增强 561300 | 前两只同 A 组，增强产品独立 | 沪深两种行情代码可追溯到同一标的，增强组合另有主动偏离 |
| 国泰纳指 513100、博时标普500 513500 | 均保留 | 不同股票样本、市场覆盖及集中程度。境外投资的对冲字段还需核实 |
| 华安黄金 518880、永赢黄金股 517520 | 均保留 | 国内黄金现货与沪深港黄金产业股票承担不同风险 |
| 华宝银行 512800、华宝券商 512000 | 均保留 | 银行业与证券公司行业的业务暴露不同 |
| 华泰柏瑞红利 510880、红利低波 512890 | 均保留 | 低波筛选在股息之外引入波动率约束 |
| 国泰国债 511010、十年国债 511260、博时可转债 511380 | 各自保留 | 5 年与 10 年国债的期限不同，可转债及可交换债另有信用和权益敏感性 |
| 光伏方向 17 只 | A 为 2 组，B 提案为 1 组 | 龙头 30 筛选规模、盈利并限制样本数。合并后无法独立观察龙头筛选效果 |

七个 B 提案仅覆盖规则中逐一核对的指数对。指数名称、组内成员、管理人、上市日期跨度、保留理由和损失见组表。其余方向延续 A 的分组。没有使用事后收益挑代表，没有估算持仓重合率或价格相关性。将来可在决策日用此前成交额、最新已披露规模、当时生效费率和上市年限排序，本次未建立同口径的完整执行数据，未指定或替换代表。[沪深300双行情代码](https://oss-ch.csindex.com.cn/static/html/csindex/public/uploads/indices/detail/files/zh_CN/000300_Index_Methodology_cn.pdf) · [光伏龙头30编制方案](https://oss-ch.csindex.com.cn/static/html/csindex/public/uploads/indices/detail/files/zh_CN/20231208180021-931798_Index_Methodology_cn.pdf)

## 复验、刷新与新增匹配

在仓库根目录运行，Python 3.10 或以上，仅用标准库。发布结果位于本目录内，`CURRENT` 指向完整的一代。命令中的 `observations.json`、`incoming.json`、`before/catalog.json` 和 `after/catalog.json` 由调用方指定。

```sh
python -m unittest discover -s tools/etf_catalog -p test_catalog.py -v
python tools/etf_catalog/catalog.py verify
python tools/etf_catalog/catalog.py report ./catalog-report
python tools/etf_catalog/catalog.py refresh
```

本次使用同一深交所站点的公开 HTTP 报表。采集和发布也可分步执行，便于离线审阅。

```sh
python tools/etf_catalog/catalog.py collect --sz-http observations.json
python tools/etf_catalog/catalog.py apply observations.json
python tools/etf_catalog/catalog.py reclassify
python tools/etf_catalog/catalog.py match incoming.json
python tools/etf_catalog/catalog.py diff before/catalog.json after/catalog.json
python tools/etf_catalog/catalog.py verify-pcf research/etf-catalog/evidence/szse-20261118.json 20261118.zip
```

`match` 只预览匹配。输入 JSON 可从目录一条记录复制，添加 `"symbol": "159919.SZ"`。输入至少提供证券代码，未知字段可省略；跟踪资料不全会返回待核。完整快照通过校验并建档后，`apply` 用相同规则判定已有证券更新、已有 A 组新成员、已有方向的新指数或新暴露、全新方向、待核五类。已有证券优先认作更新，改名、标的或组的变化见 `changes` 中的旧值、新值和原因。首次建库标记“初始建档”。新证券之间的组 ID 根据事实独立计算，新增类别相对于上一次已发布目录判断。

`first_seen`、`first_observed_at` 和 `last_seen` 表示发现与观测，`listing_date` 表示披露的上市日。刷新时消失的证券保留原始事实和上次观测日期，状态改为“本次未见，状态待核”，继续占用独立席位。规则版本与实际配置摘要存进每代目录。修改规则配置需升版本，并通过 `reclassify` 记录分组变化。分组不依赖成员顺序、管理人数量或组内首只证券。

`collect` 在校验后才输出输入文件。发布在同一文件系统暂存整代目录，成功后原子替换 `CURRENT`。并发发布有文件锁，早于当前观测的输入会被拒绝。同日相同事实只保留一代，即使交易所重新生成 XLSX 时容器字节改变。本次 13 项自动化测试全部通过，覆盖分页重复与截断、冲突和资料不足、上市范围、跨管理人同指数、不同方向与风格、五类新增匹配、改名和换指数、暂时消失与恢复、组 ID 稳定、失败保护及全员映射。实际目录还通过 `verify` 逐只重算并核对所有导出。

用真实证券做留出演练。把上市日为 2026 年 11 月 19 日的天弘电网设备 ETF（562720.SH）暂时从研究视图留出，再作为新增产品加入。程序将其匹配为华夏电网设备 ETF（159326.SZ）所在 A 组的新成员，两者跟踪 931994 中证电网设备主题指数。完整目录从 1,721 增至 1,722，A 和 B 的候选数均保持原值。这次演练没有改动已发布目录。

## 复算股票指数清单

板块主表固定使用 2026 年 11 月 19 日板块样本对应的指数。某只基金改名、换指数或暂时消失时，原观察指数继续保留。没有可映射的在列基金时标为待核。板块主表覆盖境内行业与主题；全股票索引包括沪深上市 ETF 所跟踪的跨境股票、宽基和风格指数。

按目录中在列产品的资产类别和跟踪标的建表。股票 ETF 共 1,625 只，其中 1,555 只已映射，70 只另列在基金映射表中待核。汇率和基金对冲条款待核的产品仍可提供已识别的标的信息，增强产品保留属性。对同一指数的沪深代码、指数发布方代码及有依据的语言别名做归一；币种、价格收益、总收益及净总收益的差异保留。名称相同、代码不同且缺乏版本证据的条目暂缓纳入。指数在目录中可辨识与历史行情已覆盖是两个独立字段口径，本次只建立目录映射。[指数别名和版本依据](../../tools/etf_catalog/equity_index_rules.json) · [标普 500 代码与收益版本](https://www.spglobal.com/spdji/zh/indices/equity/sp-500/)

```sh
python tools/etf_catalog/equity_indices.py research/etf-catalog/equity-indices/2026-11-19
python -m unittest discover -s tools/etf_catalog -p "test*.py" -v
```

## 复算每个板块的一只代表

板块的主方向指数与专项指数逐条列在配置中。只有交易所指数代码、规范名称和境内被动股票属性相符的在列 ETF 才进入板块。跨管理人的同指数产品可以竞争同一席位，新基金优先建档。新增的指数、新名称或待核证券先沿用原分组。报告同时列出每只 ETF 的严格组、方向提案组、板块身份和入选顺位。[板块规则](../../tools/etf_catalog/sector_rules.json)

用已归档的成交额即可离线复现。第一条命令会逐个核对四份已发布文件，第二条运行目录、板块筛选及股票指数映射的全部 25 项测试。

```sh
python tools/etf_catalog/sector_seats.py report research/etf-catalog/sector-seats/2026-11-19/turnover.json research/etf-catalog/sector-seats/2026-11-19
python -m unittest discover -s tools/etf_catalog -p "test*.py" -v
```

重采时给出目录观测日之前的最近完整交易日。程序用沪、深两地基准指数确认十个相同的交易日，仅请求主方向 ETF 的短窗行情。成交额来自腾讯日线的万元字段。抽查华宝银行 ETF（512800.SH）和华夏芯片 ETF（159995.SZ）各十日，与东方财富的元口径核对，单日最大绝对差分别为 27.00 元、49.19 元，均在两个数据源显示精度允许的 50 元内。两只新上市产品的交易天数不足，继续保留在成员表。数据获取失败时采集会报错；重新采集请使用新的输出路径。[腾讯日线示例](https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get?param=sh512800,day,2026-11-05,2026-11-18,10,) · [东方财富交叉核对示例](https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=1.512800&klt=101&fqt=0&fields1=f1,f2,f3,f4&fields2=f51,f52,f53,f54,f55,f56,f57&beg=20261105&end=20261118)

```sh
python tools/etf_catalog/sector_seats.py collect 2026-11-18 sector-turnover.json
python tools/etf_catalog/sector_seats.py report sector-turnover.json sector-report
```

交易窗口、指数配置和代表只用于本次筛选。席位按配置 ID 保持稳定，重采生成新的建议报告，不会替换现有代表或改动正式策略。

## 查询决策时点可知的研究目录

`as-of` 以北京时间解释纯日期，返回该天结束时已知的最后一版目录。盘前或盘中决策应传带时区的时间戳。返回值包含该版的观测时间、可用时间、规则版本、A/B 组数和待核数。`--members` 同时返回当时保存的逐只记录，包含当时的指数、分组及在列状态。后续补录或规则修订只在各自的可用时间之后可见。

```sh
python tools/etf_catalog/catalog.py as-of 2015-01-05
python tools/etf_catalog/catalog.py as-of 2026-11-19T09:30:00+08:00
python tools/etf_catalog/catalog.py as-of 2026-11-19T10:28:40+08:00
python tools/etf_catalog/catalog.py as-of 2026-11-19 --members
```

前两条返回 `no_coverage` 和退出码 3，候选数未知。第三条命中首版，返回 1,722 只、A 784 组、B 777 组。首版于 10:08:30 开始采集，取 GitHub 草稿 PR 创建时刻 10:28:40 作为完整版本已可取得的证据。已上市多年的 ETF 同样遵守这个时点。[首版证据](2026-11-19-c433b9a1b4f282ea/availability.json)

后续本地发布记录该版本就绪时的带时区时间、前一版 ID 和目录内容摘要。查询只从 `CURRENT` 沿已发布版本回溯，并核对所选目录的 SHA-256。可用时间由运行发布工具的主机时钟提供。切换失败的快照对查询不可见；重试成功时重新记录可用时间。申请一个晚于最后一次观测的日期会返回最近已知版本，实际观测时间见 `observed_at`。证券是否在决策日停牌或可成交，仍须查该日的状态和行情资料。

17 项自动化测试通过。其中 4 项检验历史查询的时间边界、同日多版与规则变更、发布中断后的重试，以及损坏的目录或版本链。

## 第二阶段的 App 接入边界

审计基线是 `release/v0.3.1` 的 `53b3951501359e18c4f6d345f18e92e308b5c974`。远端默认分支 `main` 的 `f629370` 是其祖先。研究交付在独立分支，正式行情、28 只池、界面、含费用买单预算和 ledger 3 均沿用基线。

1. **证券池及历史资格**。为每个决策日提供带版本的可选池，分别记录上市、停牌、清盘、指数和代表变更的已知日期与生效日期。在 `Market.swift`、`Archive.swift`、`PhoneMarket.swift`、`PublicFeed.swift`、`HistoryCoverage.swift`、`HistoryReview.swift` 和 `Strategies.swift` 中，将固定集合校验与排名限制改为相应时点的声明池。正式旧快照仍按原 28 只契约解析。
2. **导入、资源与展示**。调整 `tools/pack_history_import.py`、`tools/package_store.py` 的证券数约束，版本化证券规则、市场快照、来源与历史核验清单。将 `App/MarketHome.swift`、`App/ChartsView.swift` 和 `App/ResearchApp.swift` 的固定数量文案、列表与分页连接到实际池。
3. **优化器与性能**。`Sources/ResearchCore/WorkspaceSeed/策略/指标.js` 调用 `gramMatrix` 和 `minimumVariance`。`Sources/CWorkspaceJS/workspace.c` 限制维度、矩阵长度和运行预算，`Sources/CArchive/variance.c` 的 SLSQP 固定缓冲区也按 28 分配。先把全候选筛选与每次参与优化的合格证券数分开，再验证动态维度、内存、执行时间和数值对账。
4. **回放兼容**。在 `Replay.swift` 的快照和策略身份中纳入历史池版本，保留 ledger 3 费用与现金预算语义，回归校验原 28 只路径。2015 年起的回测必须重新建立各历史时点已公开、可投资且当时可筛选的产品全集，包括后来退出的产品。本次首次发现日及今天的代表可选组不能向过去回填。
