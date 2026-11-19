# 在 iPhone 上研究 109 个 ETF 方向

打开已安装的「股票研究台」一次，让 App 建立「研究工作区」。下面的 JSON 是 2026 年 11 月 19 日的研究输入，含 109 个方向、109 只代表 ETF 以及每只代表最近十个完整交易日的成交额。手机上的 JavaScript 功能可以直接读取这些字段。

## 把数据放到手机

1. 在 iPhone 下载 [etf-universe.json](https://raw.githubusercontent.com/chkf/stock/refs/heads/research/etf-catalog-phase1/research/etf-catalog/phone-workspace/2026-11-19/etf-universe.json)。如果浏览器直接显示文本，可从文件的 [GitHub 页面](2026-11-19/etf-universe.json) 点下载原文件。
2. 在「文件」里将下载的文件移到「我的 iPhone → 股票研究台 → 研究工作区 → 输入」，保留文件名 `etf-universe.json`。Safari 的下载项通常可从「文件 → 浏览 → iCloud 云盘 → 下载」找到。[Apple 下载说明](https://support.apple.com/zh-cn/102440)
3. 在能访问该目录的手机编辑器或 agent 中打开「研究工作区」。直接研究 JSON 可以从 `directions` 开始。在 App 的自定义功能中，它对应 `input.records["etf-universe"].directions`，每次点击运行都会重新读取。

## 在 App 内运行第一项实验

以下接线只需做一次。手机 agent 可以完成第 1、2 步，也可以手工编辑这三个文件。

若使用手机 agent，先让它访问「研究工作区」，再把本页链接和这句话发给它：

> 请按这页说明把 etf-universe.json 放到「输入」，把示例功能和“运行 ETF 研究”按钮追加到我现有的工作区。载入后验证空搜索返回 109 个方向，搜索“豆粕”只返回 159985.SZ。保留已有页面、操作和策略。我会自己改算法。

1. 将 [示例脚本](https://raw.githubusercontent.com/chkf/stock/refs/heads/research/etf-catalog-phase1/research/etf-catalog/phone-workspace/etf-research.js) 存为「研究工作区/设计/功能/etf-research.js」。在现有「设计/workspace.json」的 `actions` 对象中增加一项 `"etfResearch": "功能/etf-research.js"`，保留原有键值。
2. 从同一份 manifest 的 `pages.library` 找到资料页，默认是「设计/页面/资料.json」。在它的 `blocks` 数组末尾追加以下三个对象，一起保存。如使用了自定义标签页，也可追加到已显示的任意页面。

   ```json
   [
     {"type":"field","key":"etfQuery","text":"搜索方向、指数或 ETF（留空显示全部）"},
     {"type":"button","text":"运行 ETF 研究","target":"etfResearch"},
     {"type":"result","target":"etfResearch"}
   ]
   ```

3. 回到 App，点右上角文件夹 →「重新载入工作区」。打开刚才编辑的页面，搜索留空，点「运行 ETF 研究」。结果应显示 **109 个方向 · 显示 109 个**。搜索「豆粕」后再运行，应只显示 `159985.SZ`。当前 App 快照已有日线的代表数量随手机的数据而变。功能结果也会保存到「输出/etfResearch.json」。
4. 修改「设计/功能/etf-research.js」中的 `run(input)`，重新载入并再点运行，即可比较自己的算法。

## 研究字段

| 字段 | 口径 |
|---|---|
| `as_of`、`catalog_version` | 研究名单的观测日期和目录版本 |
| `directions[].id`、`asset`、`direction` | 稳定方向 ID、资产类型和中文方向名 |
| `signal_type`、`signal_code`、`signal_name` | 107 条指数、1 条黄金现货、1 条现金收益观察指标。货币基金没有共同指数，代码为 `null` |
| `etf`、`etf_name`、`selection_note` | 本期代表交易代码、简称、归组或保留理由 |
| `turnover_dates` | 顶层数组，依次列出 2026-11-05 至 2026-11-18 的十个交易日 |
| `turnover_10d_wan`、`median_turnover_wan` | 与日期逐项对应的代表 ETF 成交额及十日中位数，单位均为万元人民币 |

这份输入可用于试验分类、流动性筛选和候选排序。动量、均线或波动率需要另外提供相应的价格序列。App 给自定义功能的 `input.market` 包含已有行情的名称、分组和日线条数；指定 `fields.symbol` 时，`input.security` 可读取该只已有行情的明细。109 个方向的指数、现货、分红调整收益均需单独核对口径。正式回测继续使用原 28 只池。按历史日期做实验时，需要该日已经可得的候选名单。

从同一版目录的股票席位、基金映射、跨资产报告和已归档成交额可离线复算手机输入。

```sh
python tools/etf_catalog/phone_input.py 2026-11-19 research/etf-catalog/phone-workspace/2026-11-19/etf-universe.json
```
