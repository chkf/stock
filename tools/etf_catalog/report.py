from collections import defaultdict


def render(state, counts, groups):
    rows = state["records"]
    lines = [
        "# 沪深上市 ETF 候选筛选",
        "",
        f"本次观测始于 {state['observed_at']}。沪市在列 {counts['markets']['SH']} 只，深市在列 {counts['markets']['SZ']} 只。"
        f"目录累计 {counts['products']} 只，其中以前观测到、本次接口未见 {counts['absent_retained']} 只。",
        "",
        "| 方案 | 候选组 | 比完整目录减少 | 减少比例 |",
        "|---|---:|---:|---:|",
        f"| A · 仅严格归组 | {counts['A']} | {counts['A_reduction']} | {counts['A_reduction_pct']:.2f}% |",
        f"| B · 细分方向提案 | {counts['B']} | {counts['B_reduction']} | {counts['B_reduction_pct']:.2f}% |",
        "",
        f"在列 {counts['observed']} 只中，正式标的名称与代码可识别且无未决冲突的有 {counts['index_identified']} 只"
        f"（{counts['index_identified_pct']:.2f}%）。主资产、市场和方向均可归类的有 {counts['classified']} 只"
        f"（{counts['classified_pct']:.2f}%）。目录中 {counts['review']} 只待核，每只分别占用一个 A 候选和一个 B 候选。",
        "",
        "规则按交易所类型、正式指数名和产品全称识别资产、市场、方向及产品机制。A 要求境内被动产品的代码和规范名称同时匹配。"
        "跨境产品需核对币种、对冲与复制结构，增强产品需核对不同管理人的增强策略。此两类逐只保留。"
        "同一代码有未解释的名称冲突时，涉及成员全部待核。",
        "",
        "## 主行业或方向",
        "",
        "| 行业或方向 | 原 ETF | A | B | 待核 |",
        "|---|---:|---:|---:|---:|",
    ]
    sectors = defaultdict(list)
    for r in rows.values():
        sectors[r["industry"]].append(r)
    for sector, members in sorted(sectors.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        lines.append(
            f"| {sector} | {len(members)} | {len({r['strict'] for r in members})} | "
            f"{len({r['proposal'] for r in members})} | {sum(bool(r['review']) for r in members)} |"
        )
    lines += [
        "",
        "按资产、市场、行业、细分方向的逐项统计见 [directions.csv](directions.csv)。"
        "同一产品只有一个主方向，附加标签保存在目录。具体指数和风格继续在各细分方向内区分。",
        "",
        "## B 方案新增的方向压缩",
        "",
        "| 纳入提案的指数 | ETF 数 | A → B | 放弃的差异 |",
        "|---|---:|---:|---|",
    ]
    for syms in groups["B"].values():
        members = [rows[s] for s in syms]
        strict = {r["strict"] for r in members}
        if len(strict) < 2:
            continue
        indices = sorted(
            {r["canonical_code"] + " " + r["canonical_index"] for r in members}
        )
        lines.append(
            f"| {'、'.join(indices)} | {len(syms)} | {len(strict)} → 1 | {members[0]['proposal_loss']} |"
        )
    lines += [
        "",
        "B 只使用规则配置中列名、列代码的指数对。未计算收益、持仓重合率或价格相关性，"
        "提案需保留原有指数及每只基金的映射。",
        "",
        "## 研究池规模与代表",
        "",
        f"建议下一轮先审阅 A 的 **{counts['A']} 个候选**。若逐项接受本表的方向取舍，"
        f"研究池可降至 **{counts['B']} 个**。当前两者相差 {counts['A'] - counts['B']} 个研究席位。"
        "待核组也占席位。按未来同一决策时点可得的成交额、规模、费率及上市年限选择代表前，只输出候选组。",
        "",
        "完整目录与字段来源见 [catalog.json](catalog.json)。逐只映射见 [members.csv](members.csv)，"
        "每个组的全部代码、指数和保留理由见 [groups.csv](groups.csv)，逐只复核原因见 [review.csv](review.csv)。",
        "",
        "这些名单记录本次观测。2015 年起的回测需另建各历史时点的上市状态、已知资料、代表选择和生效日期，"
        "并覆盖后来消失的产品以及当时的交易条件。当前 App 正式池仍为 28 只。",
        "",
    ]
    return "\n".join(lines)
