"""Exercise the real Windows HTTPS listener on loopback using a packaged real snapshot."""
import argparse
import base64
import hashlib
import http.client
import json
import plistlib
from pathlib import Path
import ssl
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_store import build, digest, verify
from transfer import identity, manual_code, Pairing, server_for

IOS = Path(__file__).resolve().parents[1]


class TransferTests(unittest.TestCase):
    def test_actual_tls_resume_and_replay(self):
        folder = build(IOS.parent, IOS / ".build/packages", progress=lambda _: None)
        m = verify(folder)
        with tempfile.TemporaryDirectory(prefix="transfer-test-", dir=IOS / ".build") as tmp:
            tls, pin = identity(tmp, "127.0.0.1")
            pair = Pairing()
            with server_for(folder, "127.0.0.1", 0, tls, pair, m) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    code = manual_code("127.0.0.1", server.server_port, pin, pair.secret)
                    short = code.removeprefix("SR1-").replace("-", "")
                    raw = base64.b32decode(short + "=" * (-len(short) % 8))
                    self.assertEqual(raw[6:22], pin)
                    self.assertEqual(raw[22:], pair.secret)
                    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                    ctx.check_hostname = False
                    ctx.verify_mode = ssl.CERT_NONE
                    # Like the app, authenticate the pinned leaf BEFORE sending a pairing or bearer secret.
                    def call(path, *, proof=None, bearer=None, check=pin):
                        con = http.client.HTTPSConnection("127.0.0.1", server.server_port, context=ctx, timeout=10)
                        try:
                            con.connect()
                            leaf = con.sock.getpeercert(binary_form=True)
                            if hashlib.sha256(leaf).digest()[:16] != check:
                                raise ValueError("电脑身份不符")
                            headers = {} if bearer is None else {"Authorization": "Bearer " + bearer}
                            con.request("POST" if proof is not None else "GET", path, body=proof, headers=headers)
                            response = con.getresponse()
                            return response.status, response.read()
                        finally:
                            con.close()
                    secret = raw[22:].hex()
                    with self.assertRaisesRegex(ValueError, "身份"):
                        call("/pair", proof=secret, check=b"\0" * 16)
                    self.assertEqual(call("/manifest")[0], 403)
                    self.assertEqual(call("/pair", proof="0" * 32)[0], 403)
                    status, ticket = call("/pair", proof=secret)
                    self.assertEqual(status, 200)
                    ticket = json.loads(ticket)
                    self.assertEqual(call("/pair", proof=secret)[0], 403)
                    status, manifest = call("/manifest", bearer=ticket["token"])
                    self.assertEqual((status, digest(manifest)), (200, ticket["id"]))
                    dest = IOS / ".build/tls-received" / ticket["id"]
                    dest.mkdir(parents=True, exist_ok=True)
                    (dest / "manifest.json").write_bytes(manifest)
                    self.assertEqual(call("/chunk/0", bearer="invalid")[0], 403)
                    self.assertEqual(call(f"/chunk/{len(m['chunks'])}", bearer=ticket["token"])[0], 404)
                    with (dest / "payload.bin").open("wb") as out:
                        for i, expected in enumerate(m["chunks"]):
                            status, block = call(f"/chunk/{i}", bearer=ticket["token"])
                            self.assertEqual((status, digest(block)), (200, expected))
                            out.write(block)
                    self.assertEqual(verify(dest), m)
                    print(f"TLS 实收 {dest} · {len(m['chunks'])} 块 · {m['fileCount']} 个文件")
                finally:
                    server.shutdown()
                    thread.join()

    def test_expired_pairing(self):
        pair = Pairing()
        pair.until = time.monotonic() - 1
        self.assertIsNone(pair.claim(pair.secret.hex()))

    def test_files_workspace_and_legacy_upgrade_settings(self):
        info = plistlib.loads((IOS / "App/Info.plist").read_bytes())
        self.assertIs(info["UIFileSharingEnabled"], True)
        self.assertIs(info["LSSupportsOpeningDocumentsInPlace"], True)
        storage = (IOS / "Sources/ResearchCore/PrivateLibrary.swift").read_text("utf-8")
        self.assertIn(".documentDirectory", storage)
        self.assertIn(".applicationSupportDirectory", storage)
        self.assertIn('appendingPathComponent("研究工作区"', storage)
        self.assertNotIn("isExcludedFromBackup", storage)


if __name__ == "__main__":
    unittest.main(verbosity=2)
