"""Edit the running app's Files workspace from outside, reload it and run a newly authored feature."""
import json
import os
from pathlib import Path
import subprocess
import time


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def sim(*args):
    return run("xcrun","simctl",*args)


def write_request(root, expect="done", **request):
    temporary = root/"请求.tmp"
    temporary.write_text(json.dumps(request,ensure_ascii=False),"utf-8")
    temporary.replace(root/"请求.json")
    receipt = wait_for(root/"输出/请求状态.json",lambda r:r.get("id")==request["id"])
    if receipt.get("status") != expect:
        raise RuntimeError(f"App reported {receipt}")


def wait_for(path, predicate, seconds=100):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = json.loads(path.read_text("utf-8"))
            if predicate(result):
                return result
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.5)
    workspace = next((parent for parent in path.parents if parent.name == "研究工作区"), None)
    if workspace:
        for name in ["版本/current.json","输出/工作区状态.json","输出/newTool.json","输出/请求状态.json"]:
            evidence = workspace/name
            print(name, evidence.read_text("utf-8")[:900] if evidence.exists() else "missing", flush=True)
    raise RuntimeError(f"Timed out waiting for {path}")


def main():
    devices = json.loads(sim("list","devices","available","-j"))["devices"]
    phones = [d for runtime, group in sorted(devices.items(),reverse=True) if "iOS" in runtime
              for d in group if d["name"].startswith("iPhone") and d["isAvailable"]]
    phone = next((d for d in phones if d["state"]=="Booted"),phones[0])
    udid = phone["udid"]
    if phone["state"] != "Booted":
        sim("boot",udid)
    derived = Path(os.environ["RUNNER_TEMP"])/"workspace-simulator"
    subprocess.run(["xcodebuild","-project","StockResearch.xcodeproj","-scheme","StockResearch","-sdk","iphonesimulator",
                    "-configuration","Debug","-destination",f"platform=iOS Simulator,id={udid},arch=arm64",
                    "-derivedDataPath",str(derived),"SDKROOT=iphonesimulator","ARCHS=arm64","ONLY_ACTIVE_ARCH=YES",
                    "IPHONEOS_DEPLOYMENT_TARGET=16.0","build"],check=True)
    sim("bootstatus",udid,"-b")
    bundle = "org.stockresearch.nativephone"
    sim("install",udid,derived/"Build/Products/Debug-iphonesimulator/StockResearch.app")
    sim("launch",udid,bundle)
    root = Path(sim("get_app_container",udid,bundle,"data"))/"Documents/研究工作区"
    pointer = root/"版本/current.json"
    before = wait_for(pointer,lambda p: bool(p.get("active")))["active"]
    print(f"{phone['name']} started with workspace {before}",flush=True)
    design = root/"设计"
    manifest = json.loads((design/"workspace.json").read_text("utf-8"))
    manifest["actions"]["newTool"] = "功能/模拟器新增.js"
    manifest["pages"]["agentPage"] = "页面/手机开发.json"
    manifest["tabs"][0] = "agentPage"
    page = {"title":"手机新增页面","icon":"chart.bar","blocks":[{"type":"button","text":"计算","target":"newTool"},{"type":"result","target":"newTool"}]}
    (design/"页面/手机开发.json").write_text(json.dumps(page,ensure_ascii=False),"utf-8")
    script = design/"功能/模拟器新增.js"
    script.write_text('function run(input) { return {text: String(input.records.sample.value * 3)}; }',"utf-8")
    (root/"输入/sample.json").write_text('{"value":14}',"utf-8")
    (design/"workspace.json").write_text(json.dumps(manifest,ensure_ascii=False),"utf-8")
    write_request(root,id="first-reload",operation="reload")
    now = wait_for(pointer,lambda p:p.get("active")!=before)["active"]
    print(f"Loaded new page and function in workspace {now}",flush=True)
    write_request(root,id="first-run",operation="run",target="newTool")
    wait_for(root/"输出/newTool.json",lambda r:r.get("text")=="42")
    (root/"输入/sample.json").write_text('{"value":21}',"utf-8")
    write_request(root,id="file-agent",operation="run",target="newTool")
    wait_for(root/"输出/newTool.json",lambda r:r.get("text")=="63")
    sim("terminate",udid,bundle)
    (root/"输出/newTool.json").unlink()
    sim("launch",udid,bundle)
    write_request(root,id="after-restart",operation="run",target="newTool")
    wait_for(root/"输出/newTool.json",lambda r:r.get("text")=="63")
    script.write_text("function run(","utf-8")
    write_request(root,expect="error",id="broken-reload",operation="reload")
    wait_for(root/"输出/工作区状态.json",lambda r:r.get("ok") is False and r.get("active")==now)
    assert json.loads(pointer.read_text())["active"]==now
    write_request(root,id="recovery-run",operation="run",target="newTool")
    wait_for(root/"输出/newTool.json",lambda r:r.get("text")=="63")
    print(f"{phone['name']}: file-only requests loaded an external page and new function, produced 42 and 63, survived a restart and a broken edit.",flush=True)


if __name__=="__main__":
    main()
