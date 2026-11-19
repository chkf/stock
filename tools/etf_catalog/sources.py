"""Current exchange listings only. No market history endpoints."""

import hashlib
import html
import json
import math
import re
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

SH = "https://query.sse.com.cn/commonSoaQuery.do"
SH_DETAIL = "https://query.sse.com.cn/commonQuery.do"
SZ = "https://fund.szse.cn/api/report/ShowReport/data"
F10 = "https://fundf10.eastmoney.com/jbgk_{}.html"
SH_REF = "https://www.sse.com.cn/assortment/fund/list/"
SZ_REF = "https://fund.szse.cn/fund/marketdata/etf/index.html"
UNKNOWN = "未知"


def clean(value):
    value = html.unescape(re.sub(r"<[^>]*>", "", str(value or ""))).strip()
    return UNKNOWN if value in {"", "-", "--", "无", "null"} else value


def get(url, params=None, ref=None, as_json=True, binary=False):
    address = url + ("?" + urlencode(params) if params else "")
    request = Request(
        address, headers={"Referer": ref or url, "User-Agent": "Mozilla/5.0"}
    )
    for attempt in range(3):
        try:
            with urlopen(request, timeout=25) as response:
                payload = response.read()
                if binary:
                    return payload
                body = payload.decode("utf-8-sig")
            return json.loads(body) if as_json else body
        except (OSError, ValueError):
            if attempt == 2:
                raise
            time.sleep(1 + attempt)


def _codes_digest(codes):
    return hashlib.sha256("\n".join(sorted(codes)).encode()).hexdigest()


def paged(fetch, key):
    """Use server geometry, reject duplicates, drift, truncation and wrong pages."""
    rows = {}
    sizes = []
    first = fetch(1)
    total, pages, size, asof = first[:4]
    if total < 1 or size < 1 or pages != math.ceil(total / size):
        raise ValueError(f"Invalid page metadata {first[:4]}")
    for n in range(1, pages + 1):
        meta = first if n == 1 else fetch(n)
        if meta[:4] != first[:4] or meta[4] != n:
            raise ValueError(f"Pagination changed at {n}: {meta[:5]}")
        data = meta[5]
        if len(data) != min(size, total - len(rows)):
            raise ValueError(f"Incomplete page {n}")
        for row in data:
            code = clean(row[key])
            if not re.fullmatch(r"[0-9]{6}", code) or code in rows:
                raise ValueError(f"Duplicate or invalid security {code} on page {n}")
            rows[code] = row
        sizes.append(len(data))
    if len(rows) != total:
        raise ValueError("Total mismatch")
    return rows, dict(
        total=total,
        pages=pages,
        page_size=size,
        page_lengths=sizes,
        source_asof=asof,
        codes_sha256=_codes_digest(rows),
    )


def sh_page(n):
    params = {
        "sqlId": "FUND_LIST",
        "isPagination": "true",
        "fundType": "00",
        "order": "fundCode|asc",
        "pageHelp.pageNo": n,
        "pageHelp.pageSize": 50,
        "pageHelp.beginPage": n,
        "pageHelp.endPage": n,
        "pageHelp.cacheSize": 1,
    }
    reply = get(SH, params, SH_REF)
    m = reply["pageHelp"]
    return (
        int(m["total"]),
        int(m["pageCount"]),
        int(m["pageSize"]),
        UNKNOWN,
        int(m["pageNo"]),
        reply["result"],
    )


def sz_page(table, n, url=SZ):
    params = {"SHOWTYPE": "JSON", "CATALOGID": table, "TABKEY": "tab1", "PAGENO": n}
    entry = get(url, params, SZ_REF)[0]
    m = entry["metadata"]
    if m["catalogid"] != table or m["tabkey"] != "tab1" or entry.get("error"):
        raise ValueError(f"Invalid SZSE table {table}")
    return (
        int(m["recordcount"]),
        int(m["pagecount"]),
        int(m["pagesize"]),
        clean(m["subname"]),
        int(m["pageno"]),
        entry["data"],
    )


def trading_date(s):
    return f"{s[:4]}-{s[4:6]}-{s[6:]}" if re.fullmatch(r"\d{8}", s) else clean(s)


def profile(symbol):
    code, exchange = symbol.split(".")
    if exchange == "SH":
        values = get(
            SH_DETAIL,
            {"sqlId": "COMMON_JJZWZ_JJLB_JJXQ_JBXX_C", "FUND_CODE": code},
            "https://etf.sse.com.cn/",
        )["result"]
        if not values:
            return {}
        if len(values) != 1 or values[0]["FUND_CODE"] != code:
            raise ValueError(f"Wrong SSE profile for {symbol}")
        r = values[0]
        return {
            "full_name": clean(r["FUND_NAME"]),
            "profile_index": clean(r["INDEX_NAME"]),
            "profile_type": clean(r["FUND_TYPE"]),
        }
    try:
        page = get(F10.format(code), as_json=False)
    except HTTPError as error:
        if error.code in (404, 410):
            return {}
        raise

    def field(name):
        match = re.search(name + r"</th>\s*<td[^>]*>([^<]*)", page)
        return clean(match[1]) if match else UNKNOWN

    if not field("基金代码").startswith(code):
        raise ValueError(f"Missing or mismatched profile identity for {symbol}")
    return {
        "full_name": field("基金全称"),
        "profile_index": field("跟踪标的"),
        "profile_type": field("基金类型"),
    }


def assemble(sh, sh_meta, sz, sz_meta, funds, funds_meta, profiles, start):
    if sz_meta["source_asof"] != funds_meta["source_asof"]:
        raise ValueError("SZSE table dates differ")
    records = {}
    for code, r in sh.items():
        if r["fundType"] != "00":
            raise ValueError("Unexpected SSE product")
        records[code + ".SH"] = dict(
            short_name=clean(r["secNameFull"]),
            manager=clean(r["companyName"]),
            listing_date=trading_date(r["listingDate"]),
            exchange_type=clean(r["subClass"]),
            index_code=clean(r["INDEX_CODE"]),
            exchange_index=clean(r["INDEX_NAME"]),
            conflicts=[],
        )
    sz_fund_etfs = {c for c, r in funds.items() if clean(r["jjlb"]) == "ETF"}
    for code in sorted(set(sz) | sz_fund_etfs):
        primary, supplement = sz.get(code, {}), funds.get(code, {})
        conflicts = []
        if code not in sz or code not in sz_fund_etfs:
            conflicts.append("深交所ETF专表与基金列表ETF标记仅一方收录")
        if (
            primary
            and supplement
            and clean(primary["glrmc"]) != clean(supplement["glrmc"])
        ):
            conflicts.append("深交所管理人字段不一致")
        records[code + ".SZ"] = dict(
            short_name=clean(primary.get("kzjcurl") or supplement["jjjcurl"]),
            manager=clean(primary.get("glrmc") or supplement.get("glrmc")),
            listing_date=clean(supplement.get("ssrq")),
            exchange_type=clean(supplement.get("tzlb")),
            index_code=clean(primary.get("nhzs")),
            exchange_index=UNKNOWN,
            conflicts=conflicts,
        )
    for sym, record in records.items():
        extra = profiles[sym]
        record.update(
            {
                k: extra.get(k, UNKNOWN)
                for k in ("full_name", "profile_index", "profile_type")
            }
        )
    markets = {}
    for exchange in ("SH", "SZ"):
        codes = [s[:6] for s in records if s.endswith("." + exchange)]
        markets[exchange] = {"total": len(codes), "codes_sha256": _codes_digest(codes)}
    field_sources = {
        "SH": {
            "list": SH + "?sqlId=FUND_LIST&fundType=00",
            "detail": SH_DETAIL
            + "?sqlId=COMMON_JJZWZ_JJLB_JJXQ_JBXX_C&FUND_CODE={code}",
            "list_fields": "short_name,manager,listing_date,exchange_type,index_code,exchange_index",
            "detail_fields": "full_name,profile_index,profile_type",
        },
        "SZ": {
            "list": SZ + "?SHOWTYPE=JSON&CATALOGID=fund_etf&TABKEY=tab1",
            "funds": SZ + "?SHOWTYPE=JSON&CATALOGID=1000_lf&TABKEY=tab1",
            "list_fields": "short_name,manager,index_code",
            "funds_fields": "exchange_type,listing_date",
            "detail": F10.replace("{}", "{code}"),
            "detail_fields": "full_name,profile_index,profile_type",
        },
    }
    return {
        "observed_at": start,
        "markets": markets,
        "field_sources": field_sources,
        "sources": {
            "SSE_FUND_LIST": sh_meta,
            "SZSE_fund_etf": sz_meta,
            "SZSE_1000_lf": funds_meta,
        },
        "sz_only_special": sorted(set(sz) - sz_fund_etfs),
        "sz_only_general": sorted(sz_fund_etfs - set(sz)),
        "records": records,
    }


def sz_bulk(table, url=SZ):
    from exchange_files import bulk_table

    first = sz_page(table, 1, url)
    params = {"SHOWTYPE": "xlsx", "CATALOGID": table, "TABKEY": "tab1"}
    blob = get(url.removesuffix("/data"), params, SZ_REF, binary=True)
    rows, receipt = bulk_table(blob, table, first)
    tail = sz_page(table, first[1], url)
    size = first[0] - (first[1] - 1) * first[2]
    if (
        tail[:4] != first[:4]
        or tail[4] != first[1]
        or len(tail[5]) != size
        or list(rows)[-size:] != [clean(r["sys_key"]) for r in tail[5]]
    ):
        raise ValueError(f"Last page does not reconcile to {table} export")
    receipt["verified_pages"] = [1, first[1]]
    receipt["last_page_rows"] = size
    receipt["download"] = url.removesuffix("/data") + "?" + urlencode(params)
    return rows, receipt


def sh_crosscheck(sh):
    def page(n):
        params = {
            "sqlId": "COMMON_JJZWZ_JJLB_L",
            "isPagination": "true",
            "FUND_CODE_ASC": 1,
            "pageHelp.pageSize": 100,
            "pageHelp.cacheSize": 1,
            "pageHelp.pageNo": n,
            "pageHelp.beginPage": n,
            "pageHelp.endPage": n,
        }
        j = get(SH_DETAIL, params, SH_REF)
        m = j["pageHelp"]
        return (
            int(m["total"]),
            int(m["pageCount"]),
            int(m["pageSize"]),
            UNKNOWN,
            int(m["pageNo"]),
            j["result"],
        )

    rows, m = paged(page, "FUND_CODE")
    etfs = {c for c, r in rows.items() if r["CATEGORY"].startswith("F1")}
    if etfs != set(sh):
        raise ValueError("SSE ETF and all-funds classifications disagree")
    return dict(m, etf_total=len(etfs), etf_codes_sha256=_codes_digest(etfs))


def collect(sz_http=False):
    start = datetime.now(timezone(timedelta(hours=8))).isoformat(timespec="seconds")
    sh, sh_meta = paged(sh_page, "fundCode")
    cross = sh_crosscheck(sh)
    url = SZ.replace("https:", "http:") if sz_http else SZ
    sz, sz_meta = sz_bulk("fund_etf", url)
    funds, funds_meta = sz_bulk("1000_lf", url)
    codes = sorted(set(sz) | {c for c, r in funds.items() if clean(r["jjlb"]) == "ETF"})
    profiles = {}
    with ThreadPoolExecutor(max_workers=3) as ex:
        syms = [c + ".SH" for c in sh]
        profiles.update(zip(syms, ex.map(profile, syms)))
    for c in codes:
        profiles[c + ".SZ"] = profile(c + ".SZ")
        time.sleep(0.6)
    state = assemble(sh, sh_meta, sz, sz_meta, funds, funds_meta, profiles, start)
    state["sources"]["SSE_all_funds"] = cross
    return state
