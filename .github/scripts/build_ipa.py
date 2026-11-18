"""Archive the Xcode project for iPhone and export one IPA on a macOS runner."""
import argparse
import base64
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
from uuid import UUID
from zipfile import ZIP_DEFLATED, ZipFile


PROJECT = "StockResearch.xcodeproj"
SCHEME = "StockResearch"


def run(*args, capture=False):
    # Some security commands take passwords as arguments. Keep them out of exception messages.
    result = subprocess.run(args, stdout=subprocess.PIPE if capture else None)
    if result.returncode:
        raise ValueError(f"{args[0]} 执行失败（{result.returncode}），参见上方工具输出")
    return result.stdout


def profile_settings(profile, identities, requested_id):
    """Select an app ID and an installed certificate allowed by this ad hoc profile."""
    devices = profile.get("ProvisionedDevices")
    entitlements = profile["Entitlements"]
    if (not devices or profile.get("ProvisionsAllDevices") or entitlements.get("get-task-allow")
            or "iOS" not in profile.get("Platform", ())):
        raise ValueError("请选择包含已登记 iPhone 的 iOS Ad Hoc 描述文件")
    if profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError("Apple 描述文件已过期")
    pattern = entitlements["application-identifier"].split(".", 1)[1]
    bundle_id = requested_id or (pattern if "*" not in pattern else "org.stockresearch.nativephone")
    if (not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id)
            or not re.fullmatch(re.escape(pattern).replace(r"\*", ".*"), bundle_id)):
        raise ValueError("请将仓库变量 IOS_BUNDLE_ID 设为描述文件覆盖的应用标识")
    available = {value.upper() for value in re.findall(r"^\s*\d+\)\s+([0-9A-Fa-f]{40})\s", identities, re.MULTILINE)}
    # Xcode accepts a signing identity's SHA-1 fingerprint as a certificate selector.
    allowed = [hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]]
    identity = next((sha for sha in allowed if sha in available), None)
    if not identity:
        raise ValueError("P12 中可用的签名身份与描述文件列出的证书不匹配")
    return bundle_id, profile["TeamIdentifier"][0], str(UUID(profile["UUID"])).upper(), identity


def prepare_signing(work, cleanup):
    cert64 = os.environ.pop("IOS_P12_BASE64", "")
    pwd = os.environ.pop("IOS_P12_PASSWORD", "")
    profile64 = os.environ.pop("IOS_PROFILE_BASE64", "")
    if not cert64 or not profile64:
        raise ValueError("需要在仓库 Actions Secrets 设置 IOS_P12_BASE64 和 IOS_PROFILE_BASE64，以及 P12 对应的密码")
    certificate, profile = work / "signing.p12", work / "signing.mobileprovision"
    certificate.write_bytes(base64.b64decode("".join(cert64.split()), validate=True))
    profile.write_bytes(base64.b64decode("".join(profile64.split()), validate=True))
    meta = plistlib.loads(run("security", "cms", "-D", "-i", profile, capture=True))
    keychain = work / "signing.keychain-db"
    keypass = secrets.token_urlsafe(32)
    previous = shlex.split(run("security", "list-keychains", "-d", "user", capture=True).decode())
    run("security", "create-keychain", "-p", keypass, keychain)
    cleanup.callback(run, "security", "delete-keychain", keychain)
    run("security", "set-keychain-settings", "-lut", "7200", keychain)
    run("security", "unlock-keychain", "-p", keypass, keychain)
    run("security", "import", certificate, "-k", keychain, "-P", pwd, "-f", "pkcs12",
        "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keypass, keychain)
    run("security", "list-keychains", "-d", "user", "-s", keychain, *previous)
    cleanup.callback(run, "security", "list-keychains", "-d", "user", "-s", *previous)
    identities = run("security", "find-identity", "-v", "-p", "codesigning", keychain, capture=True).decode()
    bundle, team, profile_id, sha = profile_settings(meta, identities, os.environ.get("IOS_BUNDLE_ID"))
    destination = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles" / (profile_id + ".mobileprovision")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.read_bytes() != profile.read_bytes():
            raise ValueError("构建机上已有相同编号而内容不同的描述文件")
    else:
        shutil.copyfile(profile, destination)
        cleanup.callback(destination.unlink, missing_ok=True)
    options = {"method": "release-testing", "destination": "export", "signingStyle": "manual",
               "teamID": team, "signingCertificate": sha, "provisioningProfiles": {bundle: profile_id}}
    (work / "ExportOptions.plist").write_bytes(plistlib.dumps(options))
    return [f"STOCK_APP_BUNDLE_ID={bundle}", f"STOCK_APP_TEAM={team}", f"STOCK_APP_PROFILE={profile_id}",
            f"STOCK_APP_IDENTITY={sha}", "STOCK_APP_SIGN_STYLE=Manual"]


def build(mode, work, output, cleanup):
    signed = mode == "ad-hoc"
    settings = prepare_signing(work, cleanup) if signed else ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
    archive = work / "StockResearch.xcarchive"
    run("xcodebuild", "-project", PROJECT, "-scheme", SCHEME, "-configuration", "Release",
        "-destination", "generic/platform=iOS", "-derivedDataPath", work / "DerivedData",
        "-archivePath", archive, *settings, "archive")
    if signed:
        export = work / "export"
        run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", export,
            "-exportOptionsPlist", work / "ExportOptions.plist")
        ipas = list(export.glob("*.ipa"))
        if len(ipas) != 1:
            raise ValueError("Xcode 未导出唯一的 IPA")
        ipa = ipas[0]
        run("ditto", "-x", "-k", ipa, work / "verified")
        run("codesign", "--verify", "--deep", "--strict", work / "verified/Payload/StockResearch.app")
    else:
        payload = work / "Payload"
        payload.mkdir()
        run("ditto", archive / "Products/Applications/StockResearch.app", payload / "StockResearch.app")
        ipa = work / "StockResearch-unsigned.ipa"
        with ZipFile(ipa, "w", compression=ZIP_DEFLATED) as packed:
            for entry in sorted(payload.rglob("*")):
                if entry.is_file():
                    packed.write(entry, entry.relative_to(work).as_posix())
    with ZipFile(ipa) as z:
        prefix = "Payload/StockResearch.app/"
        info = plistlib.loads(z.read(prefix + "Info.plist"))
        if z.testzip() or "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", ()) or not z.getinfo(prefix + info["CFBundleExecutable"]).file_size:
            raise ValueError("IPA 的设备平台、文件内容或主程序无效")
        if (prefix + "embedded.mobileprovision" in z.namelist()) != signed:
            raise ValueError("导出 IPA 的描述文件与所选签名模式不一致")
        resources = {name.rsplit("/", 1)[-1] for name in z.namelist() if name.startswith(prefix) and ".bundle/" in name}
        if not {"PublicRules.json", "Reference.json", "XSHG.txt"}.issubset(resources):
            raise ValueError("IPA 缺少交易日历或对账资源")
        seed = Path("Sources/ResearchCore/WorkspaceSeed")
        archived = {}
        marker = ".bundle/WorkspaceSeed/"
        for member in z.infolist():
            name = member.filename
            if not member.flag_bits & 0x800:
                try: name = name.encode("cp437").decode("utf-8")
                except (UnicodeError, ValueError): pass
            if name.startswith(prefix) and marker in name and not member.is_dir():
                archived[name.split(marker,1)[1]] = member
        for file in seed.rglob("*"):
            if file.is_file():
                key = file.relative_to(seed).as_posix()
                if key not in archived or z.read(archived[key]) != file.read_bytes():
                    raise ValueError("IPA 工作区文件校验失败：" + key)
        if not info.get("UIFileSharingEnabled") or not info.get("LSSupportsOpeningDocumentsInPlace"):
            raise ValueError("IPA 未启用文件 App 的就地编辑")
    if signed:
        options = plistlib.loads((work / "ExportOptions.plist").read_bytes())
        embedded = work / "verified/Payload/StockResearch.app/embedded.mobileprovision"
        meta = plistlib.loads(run("security", "cms", "-D", "-i", embedded, capture=True))
        if options["provisioningProfiles"].get(info["CFBundleIdentifier"]) != meta["UUID"].upper():
            raise ValueError("导出包的应用标识或内嵌描述文件与所选签名材料不同")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ipa, output / f"StockResearch-{mode}.ipa")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("unsigned", "ad-hoc"))
    mode = parser.parse_args().mode
    try:
        runner_temp = Path(os.environ["RUNNER_TEMP"])
        with tempfile.TemporaryDirectory(dir=runner_temp) as temp, ExitStack() as cleanup:
            build(mode, Path(temp), runner_temp / "stockresearch-ipa", cleanup)
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
