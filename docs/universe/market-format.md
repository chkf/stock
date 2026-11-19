# 冻结行情格式 `etf-universe-1`

`Hash` 表示原件**确切字节**的 SHA-256（64 位小写 hex），不是文件名、URL 或可变指针；`Day` 表示上海 `YYYY-MM-DD`。原件可以是公开公告、交易所文件等二进制内容；结构化记录均为 UTF-8 JSON。生产者负责核对原件与现实世界含义。摘要保证未换件，不代表发行人签名，App 不能替人鉴定 PDF 真伪或证明某份名单覆盖全市场。不要把核验日期当作事实的公开日期。

## 组织原件

以下是生成器使用的字段类型（`?` 表示可省略或 null，`[]` 表示数组）。从底层原件向上生成；例如 Python 中用 `raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")`，保存 `blobs/<hashlib.sha256(raw).hexdigest()>`。同一原件可以跨证券、区间和新快照复用。无需每次传一份全库。

```typescript
type Metadata = {effective:Day, known:Day, evidence:Hash, name:string,
  assetClass:string, role:string, group:string, indexID:string, candidate:boolean};
type ListingProof = {symbol:string, instrument:"ETF", listed:Day, known:Day, source:Hash};
type TerminalProof = {symbol:string, inactiveFrom:Day, known:Day, source:Hash};
type MetadataProof = {symbol:string, verified:true, classification:Metadata};
type Listing = {listed:Day, listingEvidence:Hash, terminal?:Day, terminalEvidence?:Hash,
  metadata:Metadata[]};
type Catalog = Record<Symbol, Listing>;
type ScopeProof = {schema:"etf-scope-review-1", scope:string, from:Day, through:Day,
  catalog:Hash, sources:Hash[]};
type Manifest = {schema:"etf-universe-1", from:Day, through:Day, catalog:Hash,
  scopeEvidence:Hash, partitions:Record<Symbol,Hash[]>};
type Session = {state:"trading"|"halted"|"no_trades_confirmed", known:Day,
  evidence:Hash, execution:"CN_ETF_T1_LOT100", upper?:number, lower?:number};
type Partition = {schema:"etf-session-partition-1", symbol:Symbol, from:Day, through:Day,
  quotes:Hash, audit:Hash, sessions:Record<Day,Session>};
type QuoteReceipt = {schema:"eastmoney-raw-1", symbol:Symbol, from:Day, through:Day,
  url:string, body:Hash};
type Event = {date:Day, announced:Day, record_date:Day, source:Hash,
  supported:boolean, date_needs_reconciliation:boolean, cash_per_share?:number,
  payment_date?:Day, share_factor?:number, exact_factor?:string,
  settlement?:"single_account_shares", share_timing?:"before_open"|"record_close",
  available_date?:Day, rounding?:"ceil"|"floor"};
type ActionAudit = {schema:"etf-action-audit-1", symbol:Symbol, from:Day, through:Day,
  sources:Hash[], events:Event[]};
```

行动记录只接受本版列出的字段。多出的事件字段、分红混入拆合或清算结算条款、拆合另带现金支付日，均从事件日起阻断；不要丢弃原条款后改报成普通分红。

- `Symbol` 是交易所六位代码加 `.SH` / `.SZ`。不是满足正则就视为 ETF：`ListingProof` 须匹配代码、上市日、产品类型及原件摘要；`known<=listed`。终止日若提供，必须指向对应 `TerminalProof`，且 `known<=inactiveFrom`。终止日是**首个不再上市的日期**，不作为假定卖出日。
- `ScopeProof` 声明并核对这一个研究范围（不必是全市场）在所给期间的组成，包括消失过或后来上市的产品；它绑定目录摘要及非空依据列表。`partitions` 是采集范围，不是候选名单；可以先收个别分区。目录内实际上市但未提供分区的交易日记为缺数，挂载不删除该产品，相关回测被阻断。
- 每一条 `metadata` 的 `evidence` 指向 `MetadataProof`；该证明的 `classification` 除 `evidence` 指向独立来源原件外，所有字段必须与目录行相同。`group` 为严格方向/归组 ID，`indexID` 为已核指数身份；确无基准和基准未知不能混用。基础资格必须显式提供，不把未知补成 true。分类按 `(effective,known)` 升序唯一；使用截止收盘已生效且已公开的最后一条。上市后没有这样的记录，该日不能发布正式结果。
- 每个分区的两端是交易日，包含两端，同一证券不能重叠。`sessions` 仅登记生命周期内交易日；`known` 是该日收盘事实的可知日，必须等于键。`upper/lower` 是该交易日经来源核对的真实价格限制，不能从今天的规则倒推。交易日必须齐全且与原价范围一致。停牌/确证无成交需原件，若有日线其成交量与额必须为零。该版本只接收与现有账簿一致的单账户、100 份整手、买入份额下个交易日可卖的执行口径；无法这样核定的产品或日期请标不支持，不要把 T+0 假称 T+1。
- `quotes` 是收集回执，须匹配交易所、证券、区间和 `PublicFeed.universeURL` 的规范 URL；`body` 为不复权东财日 K 原响应。核对 `rc==0,data.code,data.market,data.klines`。日线顺序：`日,开,收,高,低,量(手),额(人民币元)`，对应 `f51…f57, fqt=0, klt=101`；SH 的 market=1，SZ=0。不要用调整价冒充原价或交给成交层。109 方向文件的「万元」十日统计不能替代这里的 `f57`。
- `audit` 必须是该证券**整个分区**的行动完整性审核；核定无行动时也必须有非空底层凭证并明确 `events:[]`。分红或拆合事件都要有 `date`（除权）、`announced`（不晚于登记日的公开日）、`record_date`、`source`（在 `audit.sources` 内）、`supported:true,date_needs_reconciliation:false`。分红还需 `cash_per_share>0,payment_date>=date`，且登记日为前一个交易日。拆合需 `share_factor>0, exact_factor`（精确十进制字符串）、`available_date`、`settlement:"single_account_shares"` 和 `share_timing:"before_open"` 或 `"record_close"`；非整数比例须有 `rounding:"ceil"|"floor"`。同日登记的日终拆合要求已证停牌且稍后才可卖。不识别的清算方式、未核行动不能用空数组代替。逐日复权公式是 `前信号 × 本日估值 / ((前原价估值 − 每份现金) / 份额比例)`；停牌使用除权参考估值。起点缺行动前参考或中间缺价时，复权链不能自动重置。

## 手机采集与缓存

- 可选单项网络请求：`{"id":"quotes-01","operation":"quotes","target":"partition","fields":{"symbol":"<六位代码.交易所>","start":"2024-12-02","end":"2024-12-31"}}`。每次只请求一只、1–125 个已收盘交易日，不发起全市场更新。`done` 中的 `message` 是 `QuoteReceipt` 摘要；**只完成采集，不代表回测或审核完成**。应用不会替你自动创建上市、状态、元数据及无公司行动证明。
- 长区间拆为互不重叠的证券/日期段；已完成的规范 URL 使用同一内容寻址缓存，不重复下载。单项失败/取消不改当前快照、不影响其他已完成项；重试该段，直到有原件、已证停牌或明确阻断原因。同 URL 有正式修订时以**新证据、新分区、新 manifest**提交，不覆盖旧件。
- 新提供的原件、结构化记录和 manifest 本体放 `研究工作区/目录行情/blobs/<Hash>`。`catalog` 请求的 target 是 manifest 的 Hash。挂载时按需将未缓存且 SHA 符合的原件拷入 `数据/universe-v1/blobs/`；已缓存的原件仍复验。失败留下有效缓存用于续传，旧 `current.json` 保持不变；成功才原子写独立指针。重启/重放使用冻结缓存，不依赖暂存区。要回到旧代，显式使用旧 manifest 摘要挂载即可。
- 已经使用 Archive 的场合：`data/advice/market/latest.json` 的 `hash/as_of` 指 manifest 原文摘要和截止日；manifest 仍打包到 `data/advice/market/snapshots/<hash>.json.gz`，其引用的原件位于 `data/advice/market/blobs/<Hash>`。与手机使用同一个解析/审核器。**本机目录流程不要求走 Archive、重新配对或替换原价库**。

原件最大 16 MiB，单快照去重后读取预算 256 MiB，目录×请求交易日预算 300 万格；`screen` 最多 32,768 只当时可见证券，JS 每阶段最多 20 万证券日期格、证券 JSON 最多 8 MiB。它们是拒绝上限，不是对 iPhone RAM 或耗时的保证。该实现分区读取原件、在内存中保留本代已核序列，不是磁盘流式的无限规模引擎。
