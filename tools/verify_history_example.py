"""Reproduce the local public-data example and exercise the native import verifier. No network access needed."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from zipfile import ZipFile

sys.path.insert(0,str(Path(__file__).resolve().parent))
from prepare_import_regression import prepare

ROOT = Path(__file__).resolve().parents[1]


def reproduce(output, binary=None):
    output.mkdir(parents=True,exist_ok=False)
    if binary is None:
        subprocess.run(["swift","build","--product","research-check"],cwd=ROOT,check=True)
        directory=subprocess.check_output(["swift","build","--show-bin-path"],cwd=ROOT,text=True).strip()
        binary=Path(directory)/"research-check"
    fixture=ROOT/"fixtures/history/public-example.zip"
    expected=(fixture.parent/"public-example.sha256").read_text("ascii").split()[0]
    if hashlib.sha256(fixture.read_bytes()).hexdigest()!=expected:
        raise ValueError("本地验证样例摘要不符")
    with ZipFile(fixture) as archive:
        archive.extractall(output)
    subprocess.run([binary,"--history-example",output/"case",output/"phone",output/"回填对账.json",output/"verified"],check=True)
    packages=output/"packages"
    prepare(output/"verified",packages)
    ids=json.loads((packages/"test-packages.json").read_bytes())
    subprocess.run([binary,"--history-import",packages/ids["valid"],output/"导入对账.json",packages/ids["invalid"]],check=True)
    print("可直传的已核样例",packages/ids["valid"])
    return packages/ids["valid"]


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--out",type=Path,required=True,help="一个尚未存在的测试输出目录")
    parser.add_argument("--binary",type=Path,help="指定已本地构建的 research-check")
    args=parser.parse_args()
    reproduce(args.out.resolve(),args.binary.resolve() if args.binary else None)
