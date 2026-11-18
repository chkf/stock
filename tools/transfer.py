"""Private LAN snapshot/project transfer. No account data is included in a URL or log."""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import secrets
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
from package_store import build, verify, CHUNK, encoded


def lan_address():
    ips = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
    return next((ip for *_, (ip, _) in ips if ipaddress.ip_address(ip).is_private
                 and not ipaddress.ip_address(ip).is_loopback), "127.0.0.1")


def identity(directory, ip):
    git = shutil.which("git")
    candidates = [shutil.which("openssl")]
    if git:
        for parent in Path(git).parents:
            candidates += [parent / "mingw64/bin/openssl.exe", parent / "usr/bin/openssl.exe"]
    binary = next((str(p) for p in candidates if p and Path(p).is_file()), None)
    if not binary:
        raise ValueError("电脑需要 OpenSSL；可安装 Git for Windows 或将 openssl 加入 PATH")
    cert, key = Path(directory) / "certificate.pem", Path(directory) / "ephemeral-key.pem"
    subprocess.run([binary, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1",
                    "-subj", "/CN=StockResearchTransfer", "-addext", "subjectAltName=IP:" + ip,
                    "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True, timeout=45)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text("ascii"))
    return ctx, hashlib.sha256(der).digest()[:16]


class Pairing:
    def __init__(self):
        self.secret = secrets.token_bytes(16)
        self.bearer = None
        self.until = time.monotonic() + 600
        self.lock = threading.Lock()

    def claim(self, text):
        with self.lock:
            if not self.secret or time.monotonic() >= self.until or not text.isascii() or not hmac.compare_digest(text, self.secret.hex()):
                return None
            self.secret = None
            self.bearer = secrets.token_hex(32)
            self.until = time.monotonic() + 24 * 3600
            return self.bearer

    def authorized(self, text):
        with self.lock:
            return bool(self.bearer and time.monotonic() < self.until and hmac.compare_digest(text, "Bearer " + self.bearer))


def manual_code(host, port, pin, secret):
    raw = socket.inet_aton(host) + struct.pack(">H", port) + pin + secret
    value = base64.b32encode(raw).decode().rstrip("=")
    return "SR1-" + "-".join(value[i:i + 5] for i in range(0, len(value), 5))


def qr(code):
    from vendor.qrcodegen import QrCode
    grid = QrCode.encode_text(code, QrCode.Ecc.LOW)
    size, border = grid.get_size(), 4
    def dark(x, y):
        return 0 <= x < size and 0 <= y < size and grid.get_module(x, y)
    # Invert block glyphs so ordinary dark consoles still show a white quiet zone.
    for y in range(-border, size + border, 2):
        print("".join(("█", "▄", "▀", " ")[2 * dark(x, y + 1) + dark(x, y)]
                      for x in range(-border, size + border)))


def server_for(folder, host, port, tls, pairing, manifest):
    package_id = folder.name
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def setup(self):
            super().setup()
            self.connection.settimeout(30)

        def send(self, status, data=b"", kind="application/json"):
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.path != "/pair":
                return self.send(404)
            if self.headers.get("Content-Length") != "32":
                return self.send(403)
            token = pairing.claim(self.rfile.read(32).decode("ascii", errors="replace"))
            if not token:
                return self.send(403)
            self.send(200, encoded(dict(token=token, id=package_id)))

        def do_GET(self):
            auth = self.headers.get("Authorization", "")
            if not auth.isascii() or not pairing.authorized(auth):
                return self.send(403)
            if self.path == "/manifest":
                return self.send(200, (folder / "manifest.json").read_bytes())
            part = self.path.removeprefix("/chunk/")
            if self.path == part or len(part) > 8 or not part.isascii() or not part.isdecimal():
                return self.send(404)
            i = int(part)
            if i >= len(manifest["chunks"]):
                return self.send(404)
            with (folder / "payload.bin").open("rb") as f:
                f.seek(i * CHUNK)
                data = f.read(CHUNK)
            return self.send(200, data, "application/octet-stream")

    server = ThreadingHTTPServer((host, port), Handler)
    server.socket = tls.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    return server


def main():
    parser = argparse.ArgumentParser(description="股票研究台 · 电脑直传")
    parser.add_argument("action", choices=["pack", "serve", "verify"])
    parser.add_argument("--root", type=Path, default=TOOLS.parents[1])
    parser.add_argument("--out", type=Path, default=TOOLS.parent / ".build/packages")
    parser.add_argument("--profile", choices=["snapshot", "project"], default="snapshot")
    parser.add_argument("--market-only", action="store_true", help="只打包已形成的 advice-market-v1 行情、指针及其逐件来源")
    parser.add_argument("--package", type=Path)
    parser.add_argument("--chart-root", type=Path, help="已移动的外部交付图目录，仅按原研究指定的文件名和证据匹配")
    parser.add_argument("--host", default=None, help="电脑的局域网 IPv4 地址")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    if args.action == "verify" and not args.package:
        parser.error("verify 需要 --package")
    folder = args.package.resolve() if args.package else build(args.root, args.out, args.profile, chart_root=args.chart_root, market_only=args.market_only)
    manifest = verify(folder)
    print(f"清单 {folder.name}\n文件 {manifest['fileCount']} · 字节 {manifest['totalBytes']} · 快照 {manifest['snapshot']['hash']}")
    if args.action != "serve":
        return
    host = args.host or lan_address()
    ip = ipaddress.IPv4Address(host)
    private = any(ip in ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                                              "169.254.0.0/16", "127.0.0.0/8"))
    if not private:
        raise ValueError("请选择本机局域网 IPv4 地址")
    with tempfile.TemporaryDirectory(prefix="stock-research-tls-") as tmp:
        tls, pin = identity(tmp, host)
        pair = Pairing()
        with server_for(folder, host, args.port, tls, pair, manifest) as server:
            code = manual_code(host, server.server_port, pin, pair.secret)
            print("iPhone 打开「资料库 → 从电脑直传」。扫描或输入下方一次性配对码，10 分钟内有效。")
            print(code, flush=True)
            qr(code)
            print(f"本机 {host}:{server.server_port} · 传输中请保持窗口打开，Ctrl+C 结束。", flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass


if __name__ == "__main__":
    main()
