"""Turn a verified native market snapshot plus its original evidence into a stock-transfer-1 directory."""
import argparse
import gzip
import json
from pathlib import Path
import shutil
import sys
from tempfile import TemporaryDirectory

sys.path.insert(0,str(Path(__file__).resolve().parent))
from package_store import POINTER, build, digest, encoded, safe_relative, source_path, verify


def package(snapshot, evidence_root, out, expected):
    incoming = snapshot.read_bytes()
    raw = gzip.decompress(incoming) if incoming.startswith(b"\x1f\x8b") else incoming
    if digest(raw) != expected:
        raise ValueError("原始快照与指定 SHA-256 不符")
    market = json.loads(raw)
    accepted = {"iphone-public-market-1", "iphone-public-market-2", "advice-market-v1"}
    if market.get("schema") not in accepted or len(market.get("securities", {})) != 28 or not market.get("sources"):
        raise ValueError("需要含 28 只 ETF、复权信号和原件索引的原生快照")
    out.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=out) as temp:
        root = Path(temp)
        for key, sha in market["sources"].items():
            relative = source_path(evidence_root, key, sha)
            dest = root / safe_relative(relative)
            if not dest.is_file():
                dest.parent.mkdir(exist_ok=True, parents=True)
                shutil.copyfile(evidence_root / relative, dest)
        if market["schema"] != "advice-market-v1":
            # Preserve the parent's exact bytes and identity whenever a different envelope is required.
            parent = f"provenance/{expected}.json"
            if parent in market["sources"] or (root / parent).exists():
                raise ValueError("快照原件路径冲突")
            (root / parent).parent.mkdir(exist_ok=True, parents=True)
            (root / parent).write_bytes(raw)
            market["sources"][parent] = expected
            market["schema"] = "advice-market-v1"
            raw = encoded(market)
        identity = digest(raw)
        path = root / f"data/advice/market/snapshots/{identity}.json.gz"
        path.parent.mkdir(exist_ok=True, parents=True)
        path.write_bytes(gzip.compress(raw, mtime=0))
        (root / POINTER).write_bytes(encoded({"hash":identity, "as_of":market["as_of"]}))
        result = build(root, out, market_only=True)
    verify(result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="按原件生成只含行情的直传包")
    for name in ("snapshot","evidence-root","out"):
        parser.add_argument("--"+name, type=Path, required=True)
    parser.add_argument("--expect-sha",required=True,help="解压后原始行情 JSON 的既有 SHA-256")
    args = parser.parse_args()
    print(package(args.snapshot,args.evidence_root,args.out,args.expect_sha))
