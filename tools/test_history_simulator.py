"""Run the wheel and reopening checks on a newly created local iPhone simulator."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0,str(Path(__file__).resolve().parent))
from verify_history_example import ROOT, reproduce
from transfer import identity, Pairing, manual_code, server_for
from package_store import verify


def output(*cmd):
    return subprocess.check_output(list(map(str,cmd)),cwd=ROOT,text=True).strip()


def run(out):
    fixtures=out/"fixture"
    package=reproduce(fixtures)
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
        host="127.0.0.1"
        for brew in ["/opt/homebrew/opt/openssl@3/bin","/usr/local/opt/openssl@3/bin"]:
            if (Path(brew)/"openssl").is_file():
                os.environ["PATH"]=brew+os.pathsep+os.environ["PATH"]
                break
        with tempfile.TemporaryDirectory() as cert:
            tls,pin=identity(cert,host)
            pairing=Pairing()
            with server_for(package,host,0,tls,pairing,verify(package)) as server:
                thread=threading.Thread(target=server.serve_forever,daemon=True)
                thread.start()
                try:
                    plan=next((out/"build/Build/Products").glob("*.xctestrun"))
                    contents=plistlib.loads(plan.read_bytes())
                    targets=[t for cfg in contents.get("TestConfigurations",[]) for t in cfg["TestTargets"]]
                    if not targets: targets=[t for t in contents.values() if isinstance(t,dict) and t.get("TestBundlePath")]
                    target=next(t for t in targets if "HistoryUITests" in str(t.get("TestBundlePath","")))
                    target.setdefault("EnvironmentVariables",{})["STOCK_TEST_PAIR"]=manual_code(host,server.server_port,pin,pairing.secret)
                    with tempfile.NamedTemporaryFile(suffix=".xctestrun",dir=plan.parent) as paired:
                        paired.write(plistlib.dumps(contents)); paired.flush()
                        subprocess.run(["xcodebuild","-xctestrun",paired.name,"-destination",f"platform=iOS Simulator,id={udid}",
                                        "-parallel-testing-enabled","NO","-resultBundlePath",str(out/"History.xcresult"),
                                        "test-without-building"],cwd=ROOT,check=True)
                finally:
                    server.shutdown(); thread.join()
        assert "account" not in json.loads(config.read_bytes())["tabs"]
        reports=[json.loads(p.read_bytes()) for p in (root/"数据/studies/v1").rglob("*.json")]
        expected_ids={"BANK_ELSE_GB","MOM20","MV","GB","SECTOR_M"}
        completed={r["strategy"] for r in reports if r.get("ledgerVersion")==3 and r["start"]=="2025-10-27"
                   and r["end"]=="2025-11-17" and r["curve"][-1]["date"]==r["end"] and r["trades"]}
        if completed!=expected_ids:
            raise RuntimeError(f"模拟 iPhone 已落盘的完整回测为 {sorted(completed)}")
        print(f"模拟 iPhone 内已实际算完并重开核验 {len(completed)} 套策略。",flush=True)
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
