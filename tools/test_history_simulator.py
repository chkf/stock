"""Run the wheel and reopening checks on a newly created local iPhone simulator."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0,str(Path(__file__).resolve().parent))
from verify_history_example import ROOT, reproduce


def output(*cmd):
    return subprocess.check_output(list(map(str,cmd)),cwd=ROOT,text=True).strip()


def run(out):
    fixtures=out/"fixture"
    package=reproduce(fixtures)
    binary=Path(output("swift","build","--show-bin-path"))/"research-check"
    inventory=json.loads(output("xcrun","simctl","list","-j"))
    runtime=max((r for r in inventory["runtimes"] if r["isAvailable"] and ".iOS-" in r["identifier"]),
                key=lambda r:tuple(map(int,r["version"].split("."))))
    choices=[x for x in runtime.get("supportedDeviceTypes",inventory["devicetypes"]) if x["name"].startswith("iPhone")]
    udid=output("xcrun","simctl","create","StockResearch-History-Test",choices[0]["identifier"],runtime["identifier"])
    sim=["xcrun","simctl"]
    build=["xcodebuild","-project","StockResearch.xcodeproj","-scheme","StockResearch","-configuration","Debug",
           "-destination",f"platform=iOS Simulator,id={udid}","-sdk","iphonesimulator","SDKROOT=iphonesimulator",
           "-derivedDataPath",str(out/"build"),"-parallel-testing-enabled","NO"]
    try:
        output(*sim,"boot",udid)
        subprocess.run(build+["build-for-testing"],cwd=ROOT,check=True)
        output(*sim,"bootstatus",udid,"-b")
        phone="org.stockresearch.nativephone"
        output(*sim,"install",udid,out/"build/Build/Products/Debug-iphonesimulator/StockResearch.app")
        root=Path(output(*sim,"get_app_container",udid,phone,"data"))/"Documents/研究工作区"
        # Existing Files design with the account tab removed and old replay fields. No active pointer is authored here.
        shutil.copytree(ROOT/"Sources/ResearchCore/WorkspaceSeed",root/"设计")
        config=root/"设计/workspace.json"
        design=json.loads(config.read_bytes())
        design["tabs"].remove("account")
        config.write_text(json.dumps(design,ensure_ascii=False),"utf-8")
        replay=root/"设计/页面/回测.json"
        page=json.loads(replay.read_text("utf-8").replace('"dateField"','"field"'))
        page["blocks"].append({"type":"replay","text":"打开独立回测"})
        replay.write_text(json.dumps(page,ensure_ascii=False),"utf-8")
        shutil.copytree(fixtures/"phone/public-market",root/"数据/public-market")
        subprocess.run([binary,"--stage-simulator-archive",package,root/"数据"],check=True)
        subprocess.run(build+["-resultBundlePath",str(out/"History.xcresult"),"test-without-building"],cwd=ROOT,check=True)
        assert "account" not in json.loads(config.read_bytes())["tabs"]
    finally:
        subprocess.run(sim+["shutdown",udid],check=False)
        subprocess.run(sim+["delete",udid],check=False)


if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--out",type=Path,help="保存 xcresult 和复验样例的新目录")
    args=parser.parse_args()
    if args.out:
        folder=args.out.resolve()
        folder.mkdir(parents=True,exist_ok=False)
        run(folder)
    else:
        with tempfile.TemporaryDirectory() as directory:
            run(Path(directory))
