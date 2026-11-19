"""Read official bulk reports without Excel or third party libraries."""

from hashlib import sha256
from io import BytesIO
import re
from zipfile import ZipFile
from xml.etree import ElementTree as ET

from sources import clean, _codes_digest


def xlsx_rows(data):
    with ZipFile(BytesIO(data)) as book:
        text = []
        if "xl/sharedStrings.xml" in book.namelist():
            text = [
                "".join(t.text or "" for t in si.iterfind(".//{*}t"))
                for si in ET.fromstring(book.read("xl/sharedStrings.xml"))
            ]
        sheet = ET.fromstring(book.read("xl/worksheets/sheet1.xml"))
        for row in sheet.iterfind(".//{*}sheetData/{*}row"):
            result = {}
            for cell in row.iterfind("{*}c"):
                col = re.match("[A-Z]+", cell.attrib["r"])[0]
                value = cell.findtext("{*}v", "")
                typ = cell.get("t")
                if typ == "s":
                    value = text[int(value)]
                if typ == "inlineStr":
                    value = "".join(t.text or "" for t in cell.iterfind(".//{*}t"))
                result[col] = clean(value)
            yield result


def bulk_table(blob, table, first_page):
    total, pages, size, asof, page, head = first_page
    if (
        page != 1
        or pages != (total + size - 1) // size
        or len(head) != min(total, size)
    ):
        raise ValueError("Invalid first page geometry")
    if table == "fund_etf":
        headers = {
            "证券代码": "sys_key",
            "证券简称": "kzjcurl",
            "拟合指数": "nhzs",
            "基金管理人": "glrmc",
        }
    else:
        headers = {
            "基金代码": "sys_key",
            "基金简称": "jjjcurl",
            "基金类别": "jjlb",
            "投资类别": "tzlb",
            "上市日期": "ssrq",
            "基金管理人": "glrmc",
        }
    cols, rows = {}, {}
    for cells in xlsx_rows(blob):
        if not cols:
            cols = {
                col: headers[value] for col, value in cells.items() if value in headers
            }
            if not cols:
                continue
            if set(cols.values()) != set(headers.values()):
                raise ValueError(f"Unexpected XLSX columns {cells}")
            continue
        r = {field: clean(cells.get(col)) for col, field in cols.items()}
        code = r["sys_key"]
        if not re.fullmatch(r"[0-9]{6}", code) or code in rows:
            raise ValueError(f"Invalid XLSX row {r}")
        if table != "fund_etf" and r["ssrq"].isdigit():
            from datetime import date, timedelta

            r["ssrq"] = (
                date(1899, 12, 30) + timedelta(days=int(r["ssrq"]))
            ).isoformat()
        rows[code] = r
    if len(rows) != total or list(rows)[: len(head)] != [
        clean(r["sys_key"]) for r in head
    ]:
        raise ValueError("Bulk and paginated reports disagree")
    return rows, dict(
        total=total,
        pages=pages,
        page_size=size,
        source_asof=asof,
        method="XLSX + JSON 第1页总数及样本",
        codes_sha256=_codes_digest(rows),
        xlsx_sha256=sha256(blob).hexdigest(),
    )


def pcf_headers(blob, day):
    """Daily SZSE PCFs. Validate XML internals, not just names in the mirror."""
    rows = {}
    with ZipFile(BytesIO(blob)) as z:
        for path in z.namelist():
            if not path.startswith("SZ/") or path == "SZ/":
                continue
            doc = ET.fromstring(z.read(path))

            def field(k):
                return clean(doc.findtext("{*}" + k))

            code = field("SecurityID")
            if (
                doc.tag != "{http://ts.szse.cn/Fund}PCFFile"
                or not re.fullmatch(r"\d{6}", code)
                or path != f"SZ/{code}.SZ.xml"
                or code in rows
                or field("SecurityIDSource") != "102"
                or field("TradingDay") != day
            ):
                raise ValueError(f"PCF file/date/security mismatch: {path}")
            rows[code] = dict(
                sys_key=code,
                kzjcurl=field("Symbol"),
                nhzs=field("UnderlyingSecurityID"),
                glrmc=field("FundManagementCompany"),
            )
    if not rows:
        raise ValueError("No SZSE PCFs")
    return rows
