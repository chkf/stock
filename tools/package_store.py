"""Read-only Windows packer. The product is a seekable stream, not a ZIP to open on iOS."""
from __future__ import annotations

import ast
import gzip
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import stat
import tempfile


CHUNK = 2 * 1024 * 1024
POINTER = "data/advice/market/latest.json"
SCHEMA = "stock-transfer-1"


def encoded(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for part in iter(lambda: handle.read(CHUNK), b""):
            sha.update(part)
    return sha.hexdigest()


def safe_relative(path):
    parts = path.split("/")
    if (not path or "\\" in path or ":" in path or "\0" in path
            or any(part in ("", ".", "..") for part in parts)):
        raise ValueError(f"非法归档路径 {path!r}")
    return path


def source_path(root, original, wanted):
    # Some older records were created on another drive or before the project moved.
    # Require a unique suffix at a known project boundary AND matching evidence bytes.
    normalized = original.replace("\\", "/")
    parts = normalized.split("/")
    if ".." in parts:
        raise ValueError("来源路径包含上级目录")
    if PureWindowsPath(original).is_absolute() or normalized.startswith("/"):
        candidates = ["/".join(parts[i:]) for i, p in enumerate(parts)
                      if p in {"data", "research", "work", "stock_research", "docs"}]
    else:
        candidates = [safe_relative(normalized)]
    matches = [rel for rel in candidates if (root / rel).is_file() and file_hash(root / rel) == wanted]
    if len(matches) != 1:
        raise ValueError(f"来源缺失、歧义或哈希错误 {original}")
    return matches[0]


def original_market(root):
    info = json.loads((root / POINTER).read_bytes())
    key = info["hash"]
    if not re.fullmatch("[0-9a-f]{64}", key):
        raise ValueError("原快照编号损坏")
    payload_path = "data/advice/market/snapshots/" + key + ".json.gz"
    with gzip.open(root / payload_path, "rb") as handle:
        payload = handle.read()
    if digest(payload) != key:
        raise ValueError("原快照解压内容的 SHA-256 不符")
    bundle = json.loads(payload)
    if (bundle["schema"] != "advice-market-v1" or bundle["as_of"] != info["as_of"]
            or len(bundle["securities"]) != 28):
        raise ValueError("原快照版本、日期或固定池异常")
    aliases = {p: source_path(root, p, h) for p, h in bundle["sources"].items()}
    return info, payload_path, aliases


def walk(folder):
    def fail(exc):
        raise exc
    for base, dirs, files in os.walk(folder, onerror=fail):
        for name in dirs + files:
            p = Path(base) / name
            info = p.lstat()
            if p.is_symlink() or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError(f"需要先显式处理外部链接 {p}")
        yield from (Path(base) / name for name in files)


def collect(root, profile, snapshot, aliases, market_only=False):
    if profile == "project":
        for top in root.iterdir():
            if top.name == "ios":
                continue
            if top.is_symlink() or getattr(top.lstat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError(f"需要先显式处理外部链接 {top}")
            if top.is_dir():
                yield from walk(top)
            else:
                yield top
        return
    if profile != "snapshot":
        raise ValueError("未知迁移范围")
    paths = {root / POINTER, root / snapshot, *(root / rel for rel in aliases.values())}
    if market_only:
        yield from paths
        return
    for name in ("research/bank_long_history_20261114/prepared_v1",
                 "research/sector_selection_20261114/prepared_new_v1",
                 "research/current_signal_20261114/raw"):
        paths.update(walk(root / name))
    for rel in aliases.values():
        if rel.endswith("/capture.json"):
            paths.update(walk((root / rel).parent))
    paths.add(root / "research/current_signal_20261114/MANIFEST.json")
    yield from paths


def external_charts(root, relocated=None):
    research = root / "research"
    outputs = {}
    for script in sorted([*research.glob("*/build_chart.py"), research / "sector_best_20261117/charts_v1/build.py"]):
        if not script.is_file():
            continue
        tree = ast.parse(script.read_bytes())
        declared = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)
                    and PureWindowsPath(n.value).is_absolute() and n.value.lower().endswith(".html")]
        for reference in declared:
            old = PureWindowsPath(reference)
            original = Path(relocated) / old.name if relocated else Path(reference)
            if not original.is_file():
                raise ValueError(f"缺少研究交付图 {reference}；可用 --chart-root 指定这些原件所在目录")
            study = script.relative_to(research).parts[0]
            key = safe_relative("external-charts/" + study + "/" + old.name)
            evidence = next((p for p in (script.parent / "chart_evidence.json", script.parent / "chart_validation.json",
                                         script.parent / "validation.json") if p.is_file()), None)
            if not evidence:
                raise ValueError(f"缺少图表验证记录 {script}")
            record = json.loads(evidence.read_bytes())
            expected = record.get("chart_sha256") or record.get("fragment_sha256") or record.get("sha256")
            if expected:
                if file_hash(original) != expected:
                    raise ValueError(f"外部图表与原交付摘要不同 {original}")
            elif study == "charts_20261114":
                payload = json.loads((script.parent / "chart_payload.json").read_bytes())
                template = (script.parent / "comparison.template.html").read_text("utf-8")
                text = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
                if original.read_text("utf-8") != template.replace("__CHART_PAYLOAD__", text):
                    raise ValueError("上证五年图与原模板及冻结数据不符")
            else:
                raise ValueError(f"缺少外部图表原始验证规则 {original}")
            outputs[key] = (original, str(old))
    return outputs


def build(root, out, profile="snapshot", progress=print, chart_root=None, market_only=False):
    root, out = Path(root).resolve(), Path(out).resolve()
    if out.is_relative_to(root) and not out.is_relative_to(root / "ios"):
        raise ValueError("项目内的输出只能位于 ios 子目录")
    out.mkdir(parents=True, exist_ok=True)
    info, snapshot, aliases = original_market(root)
    if market_only and profile != "snapshot":
        raise ValueError("仅行情模式需使用 snapshot 范围")
    sources = {p.relative_to(root).as_posix(): p for p in collect(root, profile, snapshot, aliases, market_only)}
    if profile == "project":
        for rel, (original, old_path) in external_charts(root, chart_root).items():
            if rel in sources:
                raise ValueError(f"外部图映射与原件路径冲突 {rel}")
            sources[rel] = original
            aliases[old_path] = rel
    files = sorted(sources)
    if len(set(s.casefold() for s in files)) != len(files):
        raise ValueError("归档路径冲突")
    with tempfile.TemporaryDirectory(prefix="building-", dir=out) as temp:
        stage = Path(temp) / "package"
        stage.mkdir()
        entries, hashes, pending, offset = [], [], bytearray(), 0
        with (stage / "payload.bin").open("wb") as stream:
            for i, rel in enumerate(files):
                safe_relative(rel)
                sha = hashlib.sha256()
                size = 0
                with sources[rel].open("rb") as source:
                    while block := source.read(CHUNK - len(pending)):
                        stream.write(block)
                        sha.update(block)
                        size += len(block)
                        pending.extend(block)
                        if len(pending) == CHUNK:
                            hashes.append(digest(pending))
                            pending.clear()
                entries.append(dict(path=rel, offset=offset, size=size, sha256=sha.hexdigest()))
                offset += size
                if i % 1000 == 0:
                    progress(f"打包 {i + 1}/{len(files)}")
        if pending:
            hashes.append(digest(pending))
        manifest = dict(schema=SCHEMA, profile=profile, sourceRoot=str(root), aliases=aliases,
                        snapshot=info, files=entries, fileCount=len(files), totalBytes=offset,
                        chunkSize=CHUNK, chunks=hashes)
        raw = encoded(manifest)
        (stage / "manifest.json").write_bytes(raw)
        final = out / digest(raw)
        if final.exists():
            # Regenerating an interrupted or damaged computer package must not silently reuse it.
            verify(final)
        else:
            stage.rename(final)
    progress(f"已打包 {len(files)} 个文件，{offset:,} 字节，{len(hashes)} 块")
    return final


def verify(folder):
    folder = Path(folder)
    raw = (folder / "manifest.json").read_bytes()
    if digest(raw) != folder.name:
        raise ValueError("包清单摘要不符")
    m = json.loads(raw)
    if m["schema"] != SCHEMA or m["chunkSize"] != CHUNK or len(m["files"]) != m["fileCount"]:
        raise ValueError("包清单结构不符")
    with (folder / "payload.bin").open("rb") as f:
        for h in m["chunks"]:
            block = f.read(CHUNK)
            if not block or digest(block) != h:
                raise ValueError("分块校验失败")
        if f.read(1) or f.tell() != m["totalBytes"]:
            raise ValueError("总字节数不符")
        f.seek(0)
        seen = set()
        for entry in m["files"]:
            rel = safe_relative(entry["path"]).casefold()
            if rel in seen or f.tell() != entry["offset"] or entry["size"] < 0:
                raise ValueError("归档索引不连续或路径重复")
            seen.add(rel)
            sha, left = hashlib.sha256(), entry["size"]
            while left:
                block = f.read(min(CHUNK, left))
                if not block:
                    raise ValueError("归档被截断")
                sha.update(block)
                left -= len(block)
            if sha.hexdigest() != entry["sha256"]:
                raise ValueError(f"原件校验失败 {entry['path']}")
            check_original = (rel.startswith("data/snapshots/") and rel.endswith(".csv")
                              or rel.startswith("data/advice/market/snapshots/") and rel.endswith(".json.gz")
                              or rel.startswith("data/actions/") and rel.endswith(".json"))
            if check_original:
                f.seek(entry["offset"])
                raw_file = f.read(entry["size"])
                if rel.endswith(".csv"):
                    original = Path(rel).stem
                    variants = (raw_file, raw_file.replace(b"\r\r\n", b"\r\n"), raw_file.replace(b"\r\n", b"\n"))
                    if not any(digest(v) == original for v in variants):
                        raise ValueError(f"原行情 CSV 编号不符 {rel}")
                elif rel.endswith(".gz"):
                    if digest(gzip.decompress(raw_file)) != rel.split("/")[-1][:-8]:
                        raise ValueError(f"原建议快照编号不符 {rel}")
                else:
                    saved = json.loads(raw_file)
                    expected = digest(json.dumps(saved["events"], sort_keys=True, ensure_ascii=False).encode())
                    if (not saved.get("source") or expected != saved.get("snapshot")
                            or "/snapshots/" in rel and expected != Path(rel).stem):
                        raise ValueError(f"原公司行动编号不符 {rel}")
        if f.tell() != m["totalBytes"]:
            raise ValueError("文件总大小不符")
    return m
