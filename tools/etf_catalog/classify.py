"""Taxonomy is descriptive. Only reviewed index pairs can cross an A-group boundary."""

import hashlib
import json
import re
import unicodedata

from sources import UNKNOWN as U


def norm(value):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value)).upper()


def stable_id(prefix, *parts):
    payload = json.dumps(parts, ensure_ascii=False, separators=(",", ":")).encode()
    return prefix + "-" + hashlib.sha256(payload).hexdigest()[:20]


def asset_region(symbol, r, label):
    sh = symbol.endswith(".SH")
    t = r["exchange_type"]
    if (
        t in ("05", "07", "货币市场基金")
        or "货币市场基金" in label
        or "货币型" in r["profile_type"]
    ):
        return "货币", "境内"
    if t in ("06", "38", "商品期货基金", "黄金基金") or re.search(
        "黄金交易型|上海金交易型|商品期货|豆粕期货|有色金属期货|能源化工期货", label
    ):
        return "商品", "境内" if not re.search("QDII|境外", label) else U
    debt = t in ("02", "32", "36", "37", "债券基金") or re.search(
        "国债|信用债|金融债|公司债|债券|短融|科创债|利率债|地方债|中债|可转债", label
    )
    asset = (
        "债券"
        if debt or "固收" in r["profile_type"]
        else (
            "股票"
            if (
                t in ("01", "03", "08", "09", "31", "股票基金")
                or "股票" in r["profile_type"]
                or re.search("指数|股票", label)
            )
            else U
        )
    )
    regions = [
        ("内地与香港", "沪港深|沪深港|深港通|AH价格|AH股|中国AH|AH优选"),
        ("中韩", "中韩"),
        ("亚洲多市场", "东南亚|新兴亚洲|亚太|亚洲精选"),
        ("境外中国股票", "海外中国|全球中国|中概|中国互联网[0-9]+美元"),
        (
            "美国",
            "纳斯达克|纳指|标普500|标准普尔500|标普石油|道琼斯|MSCI美国|美股|美国",
        ),
        ("日本", "日经|日本|东证指数"),
        ("德国", "德国|DAX"),
        ("法国", "法国|CAC40"),
        ("巴西", "巴西|IBOVESPA"),
        ("沙特", "沙特"),
        ("香港", "港股|香港|恒生(?!A股)|恒指"),
        ("新加坡", "新加坡"),
        ("欧洲", "欧洲"),
        ("全球", "全球"),
    ]
    for region, pattern in regions:
        if re.search(pattern, label):
            return asset, region
    if t in ("08",):
        return asset, "内地与香港"
    if (sh and t in ("33", "34", "35", "04")) or re.search(
        "QDII|跨境|境外|互挂", label
    ):
        return asset, U
    if asset != U and (
        sh
        or re.search(
            "中证|深证|创业板|科创|国证|沪深|上证|中债|A股|MSCI中国A50互联互通|中小企业100|中小创业企业400",
            label,
        )
        or debt
    ):
        return asset, "境内"
    return asset, U


def index_identity(raw, rules):
    name = raw["exchange_index"] if raw["exchange_index"] != U else raw["profile_index"]
    if "无跟踪标的" in name:
        name = U
    # SZSE sometimes publishes e.g. "399975 证券公司" in its fitting-index cell.
    source_code = raw["index_code"].strip()
    match = re.fullmatch(r"([A-Za-z0-9._-]+)\s+([^\s].*)", source_code)
    code = norm(match[1] if match else source_code)
    if not re.fullmatch(r"[A-Z0-9][A-Z0-9._-]*", code):
        code = U
    canon = rules["aliases"].get(code, {}).get(norm(name), norm(name))
    return name, rules["code_aliases"].get(code + "|" + canon, code), canon


def classification(symbol, raw, rules, present=True, ambiguous=()):
    full, short = raw["full_name"], raw["short_name"]
    exchange_name, profile_name = raw["exchange_index"], raw["profile_index"]
    if "无跟踪标的" in profile_name:
        profile_name = U
    name, code, canon = index_identity(raw, rules)
    reasons = list(raw["conflicts"])
    if code in ambiguous:
        reasons.append("同一指数代码冲突：当前目录出现未经确认的不同指数名称")
    if exchange_name != U and profile_name != U:
        other = (
            rules["aliases"].get(code, {}).get(norm(profile_name), norm(profile_name))
        )
        if canon != other:
            reasons.append("交易所与档案的指数名称不一致")
    if "无跟踪标的" in raw["profile_index"] and code != U:
        reasons.append("档案称无标的但交易所提供指数代码")
    label = norm(" ".join([name, full if full != U else short]))
    asset, region = asset_region(symbol, raw, label)
    product = U
    if "主动管理" in label:
        product = "主动"
    elif re.search("增强|指增", label):
        product = "增强"
    elif full != U and re.search("指数.*(基金|ETF)|ETF.*指数", norm(full)):
        product = "被动指数"
    if asset == "货币":
        product = "货币管理"
    if asset == "商品" and re.search("黄金交易型|上海金交易型", label):
        product = "黄金现货跟踪"
    if asset == "商品" and "期货" in label:
        product = "商品期货"
    sector, direction = U, U
    # Use index title first. Product names only supply provisional classification.
    subject = canon if canon != U else norm(full if full != U else short)
    tags = []
    if asset == "货币":
        sector, direction = "货币市场", "货币工具"
    elif asset == "商品":
        sector = "实物及期货"
        direction = next(
            (
                s
                for s in ["上海金", "黄金", "豆粕", "能源化工", "有色金属"]
                if s in label
            ),
            U,
        )
    elif asset == "债券":
        sector = "固定收益"
        direction = next(
            (
                s
                for s in [
                    "可转债",
                    "可转换",
                    "国债及政策性",
                    "政策性金融债",
                    "地方政府债",
                    "国债",
                    "科创债",
                    "科技创新公司债",
                    "信用债",
                    "公司债",
                    "短融",
                    "城投债",
                    "利率债",
                ]
                if s in subject
            ),
            "其他债券",
        )
        qualifiers = re.findall(r"\d+(?:[-至]\d+)?年|AAA|AA\+|投资级|中高等级", subject)
        if qualifiers:
            direction += "（" + "、".join(qualifiers) + "）"
    elif asset == "股票":
        for major, sub, pattern in rules["directions"]:
            if re.search(pattern, subject):
                tags.append(sub)
                if sector == U:
                    sector, direction = major, sub
        if sector == U and canon != U:
            sector, direction = "其他具名指数", canon
    style = [
        s
        for s in (
            "红利",
            "高股息",
            "低波",
            "质量",
            "价值",
            "成长",
            "等权",
            "现金流",
            "龙头",
            "ESG",
            "基本面",
            "央企",
        )
        if s in subject
    ]
    publisher = next(
        (
            p
            for pattern, p in [
                (r"^中证|^沪深300", "中证指数"),
                (r"^国证|^创业板指数", "深圳证券信息"),
                (r"^恒生", "恒生指数公司"),
                (r"^MSCI", "MSCI"),
                (r"^纳斯达克", "Nasdaq"),
                (r"^标普|^标准普尔|^道琼斯", "标普道琼斯指数"),
                (r"^富时", "富时罗素"),
            ]
            if re.search(pattern, canon)
        ),
        U,
    )
    if not present:
        reasons.append("本次接口未见，上次事实保留，状态待核")
    identified = code != U and name != U and ("指数" in canon or "INDEX" in canon)
    if not identified:
        reasons.append("缺少可交叉识别的正式标的名称或交易所指数代码")
    if asset == U or region == U or direction == U:
        reasons.append("资产、市场或主方向待核")
    if product != "被动指数":
        reasons.append("产品机制需要逐只审阅")
    if region not in ("境内", U):
        reasons.append("跨市场的汇率、对冲或复制结构待核")
    if re.search(
        "对冲|杠杆|反向|互挂|联接|合成|掉期|主动|增强|QDII|美元|港元|欧元", label
    ):
        reasons.append("特殊策略、币种或跨境结构需审阅")
    if full == U:
        reasons.append("缺少产品全称")
    if asset not in ("股票", "债券"):
        reasons.append("货币或商品工具不按股票指数规则归并")
    if re.search("LOF|联接", norm(full)):
        reasons.append("档案与交易所ETF范围冲突")
    # Domestic cash-market exposure has no cross-currency leg in the reference index.
    hedge = (
        "境内标的无跨币种敞口"
        if region == "境内"
        and asset in ("股票", "债券")
        and not re.search("美元|港元|外汇|QDII|对冲", label)
        else U
    )
    if hedge == U and "被动指数" == product:
        reasons.append("对冲属性待核")
    reasons = list(dict.fromkeys(reasons))
    strict = (
        stable_id("S", symbol)
        if reasons
        else stable_id("A", code, canon, asset, region, product, hedge)
    )
    proposal = next(
        (p for p in rules["proposals"] if p["indices"].get(code) == canon), None
    )
    b = (
        stable_id("B", proposal["id"], asset, region, product, hedge)
        if proposal and not reasons
        else strict
    )
    fine = canon if canon != U else direction
    maturity = re.search(r"\d+(?:[-至]\d+)?年", canon) if asset == "债券" else None
    credit = (
        re.search(r"AAA|AA\+|AA|投资级|中高等级", canon) if asset == "债券" else None
    )
    return dict(
        index_name=name,
        canonical_index=canon,
        canonical_code=code,
        publisher=publisher,
        index_identified=identified
        and not any(
            "指数名称不一致" in reason or "无标的" in reason or "指数代码冲突" in reason
            for reason in reasons
        ),
        bond_tenor=maturity[0] if maturity else U,
        bond_credit=credit[0] if credit else U,
        asset=asset,
        region=region,
        industry=sector,
        direction=direction,
        exposure=fine,
        style="、".join(style) or U,
        tags=list(dict.fromkeys(tags)),
        product=product,
        trading_currency="人民币",
        fund_currency=U,
        hedge=hedge,
        basis=f"交易所类别 {raw['exchange_type']}。按{'指数名称' if canon != U else '产品名称'}「{subject}」归入{sector}/{direction}，以全称核对产品机制。",
        classification_confidence=(
            "低"
            if U in (asset, region, direction)
            else "中（名称初筛）"
            if canon == U or code in ambiguous
            else "较高（标的和交易所资料）"
        ),
        confidence="待核" if reasons else "高（代码、名称及境内产品结构）",
        review=reasons,
        strict=strict,
        proposal=b,
        direction_id=stable_id("D", asset, region, sector, direction),
        proposal_loss=proposal["loss"] if b != strict else "",
        rule_version=rules["version"],
    )
