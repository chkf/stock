"""Create two standalone transfer packages in a test folder, including one with a deliberately ineligible target."""
import argparse
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

sys.path.insert(0,str(Path(__file__).resolve().parent))
from pack_history_import import package
from package_store import digest, encoded


def prepare(example, out):
    snapshot = example / "phone-verified.json"
    raw = snapshot.read_bytes()
    good = package(snapshot,example,out,digest(raw))
    data = json.loads(raw)
    start = data["history"]["from"]
    data["history"]["replayTarget"] = {"start":start,"end":start,"strategies":["MOM20"]}
    with TemporaryDirectory(dir=out) as folder:
        bad_snapshot = Path(folder)/"ineligible-test.json"
        raw = encoded(data)
        bad_snapshot.write_bytes(raw)
        bad = package(bad_snapshot,example,out,digest(raw))
    (out/"test-packages.json").write_bytes(encoded({"valid":good.name,"invalid":bad.name}))


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("example",type=Path)
    parser.add_argument("out",type=Path)
    args=parser.parse_args()
    prepare(args.example,args.out)
