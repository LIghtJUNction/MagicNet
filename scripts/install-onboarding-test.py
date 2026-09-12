#!/usr/bin/env python3
"""Host contracts for install-only onboarding; uses real BusyBox HTTP/CGI.

No device, root privileges, Internet, actual subscription or third-party Python
packages are needed. Android Binder/UI is mocked, not claimed as device-tested.
"""
from __future__ import annotations

import http.client
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "src/MagicNet"
HELPER = MODULE / "lib/magicnet/install_onboarding.sh"
BUSYBOX = shutil.which("busybox")
KAMFW = Path(os.environ.get("KAMFW_TEST_DIR", str(MODULE / "lib/kamfw")))
URL = "https://feed.example.test/subscribe?token=a+b%2F%26&x=$(id)&quote='&semi=;&pct=%25"


class Session:
    def __init__(self, timeout: int = 30, am_status: int = 0, existing: str | None = None):
        self.temp = tempfile.TemporaryDirectory(prefix="magicnet-onboarding-")
        self.root = Path(self.temp.name)
        if existing is not None:
            config = self.root / '.config/sing-box'
            config.mkdir(parents=True)
            (config / 'subscription.url').write_text(existing)
        (self.root / "lib/magicnet").mkdir(parents=True)
        shutil.copytree(MODULE / "lib/magicnet/onboarding", self.root / "lib/magicnet/onboarding")
        self.log_path = self.root / "installer-output"
        self.log = self.log_path.open("w")
        env = dict(os.environ, MODPATH=str(self.root), MAGICNET_SETUP_BUSYBOX=str(BUSYBOX),
                   MAGICNET_SETUP_TIMEOUT=str(timeout), KAMFW_TEST_DIR=str(KAMFW),
                   KAM_UI_LANGUAGE="zh", TEST_AM_RC=str(am_status))
        script = r'''
. "$1"
print() { printf '%s\n' "$*"; }
i18n() { printf '%s' "$1"; }
import() { . "$KAMFW_TEST_DIR/$1.sh"; }
magicnet_onboarding_android_am() {
    printf '%s\n' "$@" >"$MODPATH/am-arguments"
    return "$TEST_AM_RC"
}
magicnet_onboarding_collect
'''
        self.proc = subprocess.Popen([str(BUSYBOX), "ash", "-c", script, "test", str(HELPER)],
                                     env=env, stdout=self.log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
        self.port = 0
        self.token = ""
        for _ in range(350):
            args = self.root / "am-arguments"
            text = args.read_text() if args.exists() else ""
            match = re.search(r"http://127\.0\.0\.1:(\d+)/\?lang=zh#([a-f0-9]{48})", text)
            if match:
                self.port, self.token = int(match[1]), match[2]
                self.url = match[0]
                break
            if self.proc.poll() is not None:
                self.close()
                raise RuntimeError("collector failed before readiness: " + text)
            time.sleep(0.02)
        if not self.port:
            self.close()
            raise RuntimeError("collector did not become ready")

    def request(self, action: str, body: str | bytes | None = None,
                method: str = "POST", headers: dict | None = None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=12)
        defaults = {"X-Setup-Token": self.token, "Content-Type": "text/plain;charset=UTF-8"}
        defaults.update(headers or {})
        try:
            connection.request(method, "/cgi-bin/setup/" + action, body=body, headers=defaults)
            response = connection.getresponse()
            data = response.read()
            payload = data.decode() if action == 'subscriptions' and response.status == 200 else json.loads(data)
            return response.status, payload, dict(response.getheaders())
        finally:
            connection.close()

    def wait(self, timeout: int = 10):
        result = self.proc.wait(timeout=timeout)
        # A signal can reap the outer installer before its isolated collector
        # finishes EXIT cleanup. Bound that drain instead of racing the trap.
        for _ in range(100):
            if not list((self.root / ".state").glob("install-onboarding*")):
                break
            time.sleep(0.02)
        assert not list((self.root / ".state").glob("install-onboarding*")), "temporary files leaked"
        with socket.socket() as client:
            client.settimeout(1)
            assert client.connect_ex(("127.0.0.1", self.port)) != 0, "HTTP port leaked"
        return result

    def close(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(timeout=2)
        self.log.close()
        self.temp.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


@unittest.skipUnless(BUSYBOX, "BusyBox is required")
class OnboardingTests(unittest.TestCase):
    def test_pinned_framework_is_available(self):
        self.assertTrue((KAMFW / "launcher.sh").is_file(), "initialize the kamfw submodule")

    def test_shell_and_javascript_syntax(self):
        for path in [HELPER, MODULE / "customize.sh", *(MODULE / "lib/magicnet/onboarding").glob("*.sh")]:
            subprocess.run([BUSYBOX, "ash", "-n", str(path)], check=True)
        if shutil.which("node"):
            subprocess.run(["node", "--check", str(MODULE / "lib/magicnet/onboarding/app.js")], check=True)

    def test_save_preserves_literal_bytes_permissions_and_config(self):
        with Session() as session:
            config = session.root / ".config/sing-box/config.json"
            config.write_text('{"sentinel":true}\n')
            status, payload, headers = session.request("save", URL)
            self.assertEqual((status, payload), (200, {"code": "saved"}))
            self.assertEqual(headers["Cache-Control"], "no-store")
            out = session.root / ".config/sing-box/subscription.url"
            self.assertEqual(out.read_bytes(), (URL + "\n").encode())
            self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
            self.assertEqual(config.read_text(), '{"sentinel":true}\n')
            self.assertNotIn(URL, session.log_path.read_text())
            self.assertEqual(session.wait(), 0)

    def test_skip_does_not_create_subscription(self):
        with Session() as session:
            self.assertEqual(session.request("skip", "")[:2], (200, {"code": "skipped"}))
            self.assertEqual(session.wait(), 2)
            self.assertFalse((session.root / ".config/sing-box/subscription.url").exists())

    def test_timeout_closes_server_and_cleans_private_state(self):
        with Session(timeout=5) as session:
            self.assertEqual(session.wait(), 3)
            self.assertFalse((session.root / ".config/sing-box/subscription.url").exists())

    def test_signal_closes_server_and_cleans_private_state(self):
        with Session() as session:
            os.killpg(session.proc.pid, signal.SIGTERM)
            self.assertNotEqual(session.wait(), 0)

    def test_browser_failure_exits_without_manual_wait(self):
        with Session(am_status=7) as session:
            self.assertEqual(session.wait(), 1)
            self.assertNotIn(session.url, session.log_path.read_text())
            self.assertNotIn("MN_SETUP_MANUAL", session.log_path.read_text())

    def test_kamfw_launcher_keeps_default_browser_current_user_and_exit_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            recorder = Path(tmp) / "busybox-recorder"
            recorder.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >"$TEST_ARGS"\nexit 7\n')
            recorder.chmod(0o700)
            env = dict(os.environ, KAMFW_TEST_DIR=str(KAMFW), MN_SETUP_BB=str(recorder),
                       MN_SETUP_RUN=tmp, TEST_ARGS=str(Path(tmp) / "arguments"))
            script = '. "$1"; import() { . "$KAMFW_TEST_DIR/$1.sh"; }; magicnet_onboarding_open "$2"'
            result = subprocess.run([BUSYBOX, "ash", "-c", script, "test", str(HELPER), "http://127.0.0.1:33333/#test"], env=env)
            self.assertEqual(result.returncode, 7)
            args = (Path(tmp) / "arguments").read_text().splitlines()
            self.assertEqual(args, ["timeout", "5", "/system/bin/am", "start", "-a", "android.intent.action.VIEW", "-d",
                                    "http://127.0.0.1:33333/#test", "--user", "current", "-c", "android.intent.category.BROWSABLE"])
            self.assertNotIn("-n", args)  # No hard-coded browser package/component.

    def test_http_security_boundaries(self):
        with Session() as session:
            for headers in [{"X-Setup-Token": ""}, {"X-Setup-Token": "wrong"},
                            {"Origin": "https://outside.example.test"}, {"Host": "outside.example.test"},
                            {"Sec-Fetch-Site": "cross-site"}, {"Sec-Fetch-Site": "same-site"}]:
                with self.subTest(headers=headers):
                    self.assertEqual(session.request("save", URL, headers=headers)[0], 403)
            self.assertEqual(session.request("save", None, "GET")[0], 405)
            self.assertEqual(session.request("anything", "")[0], 404)
            self.assertEqual(session.request("save", URL, headers={"Content-Type": "application/json"})[0], 415)
            self.assertEqual(session.request("health", None, "GET")[0], 200)
            self.assertFalse((session.root / ".config/sing-box/subscription.url").exists())

    def test_invalid_input_cannot_publish_state(self):
        invalid = ["", "http://feed.example.test/list", "file:///etc/passwd", "javascript:alert(1)",
                   "https:///no-host", "https://user:pass@feed.example.test/x", "https://feed.example.test/x#secret",
                   "https://feed.example.test/with space", "https://feed.example.test/\n\ninvalid", "https://feed.example.test/\x00",
                   "https://feed.example.test/\x7f", "https://feed.example.test\\other/x", "https://feed.example.test:0/x",
                   "https://feed.example.test:65536/x", "https://feed.example.test:00000/x", "https://:443/x", "https://[::1]:99999/x"]
        with Session() as session:
            for value in invalid:
                with self.subTest(value=repr(value)):
                    self.assertEqual(session.request("save", value.encode())[0], 400)
            self.assertEqual(session.request("save", "https://feed.example.test/" + "a" * 8192)[0], 413)
            self.assertFalse((session.root / ".config/sing-box/subscription.url").exists())

    def test_ipv6_literal_is_staged_without_fetching(self):
        # Runtime download validation still enforces public destination checks;
        # this install-only collector performs no network resolution or fetch.
        with Session() as session:
            value = "https://[2001:db8::1]:00443/sub"
            self.assertEqual(session.request("save", value)[0], 200)
            self.assertEqual(session.wait(), 0)

    def test_existing_user_input_is_never_overwritten(self):
        with Session() as session:
            out = session.root / ".config/sing-box/subscription.url"
            out.write_text("https://existing.example.test/sub\n")
            self.assertEqual(session.request("save", URL)[:2], (409, {"code": "existing"}))
            self.assertEqual(out.read_text(), "https://existing.example.test/sub\n")

    def test_upgrade_prefill_replace_and_add(self):
        old = 'https://old.example.test/sub\n'
        with Session(existing=old) as session:
            status, payload, headers = session.request('subscriptions', method='GET')
            self.assertEqual((status, payload), (200, old))
            self.assertEqual(headers['Cache-Control'], 'no-store')
            self.assertEqual(session.request('subscriptions', method='GET', headers={'X-Setup-Token': ''})[0], 403)
            new = 'https://replacement.example.test/sub\nhttps://added.example.test/sub'
            self.assertEqual(session.request('save', new)[0], 200)
            self.assertEqual((session.root / '.config/sing-box/subscription.url').read_text(), new + '\n')
            self.assertNotIn(old.strip(), session.log_path.read_text())
            self.assertEqual(session.wait(), 0)

    def test_upgrade_skip_and_conflict_preserve_input(self):
        old = 'https://old.example.test/sub\n'
        with Session(existing=old) as session:
            out = session.root / '.config/sing-box/subscription.url'
            newer = 'https://newer.example.test/sub\n'
            out.write_text(newer)
            self.assertEqual(session.request('save', URL)[0], 409)
            self.assertEqual(session.request('skip', '')[0], 200)
            self.assertEqual(session.wait(), 2)
            self.assertEqual(out.read_text(), newer)

    def test_multiple_subscription_limit(self):
        with Session() as session:
            self.assertEqual(session.request('save', '\n'.join([URL] * 6))[0], 400)
            self.assertEqual(session.request('save', '\n'.join([URL] * 5))[0], 200)
            self.assertEqual(session.wait(), 0)

    def test_symlink_target_is_refused(self):
        with Session() as session:
            victim = session.root / "victim"
            victim.write_text("do not touch")
            (session.root / ".config/sing-box/subscription.url").symlink_to(victim)
            self.assertEqual(session.request("save", URL)[:2], (409, {"code": "unsafe_path"}))
            self.assertEqual(victim.read_text(), "do not touch")

    def test_symlink_configuration_directory_is_refused(self):
        with Session() as session:
            config = session.root / ".config/sing-box"
            config.rmdir()
            outside = session.root / "outside"
            outside.mkdir()
            config.symlink_to(outside)
            self.assertEqual(session.request("save", URL)[:2], (409, {"code": "unsafe_path"}))
            self.assertFalse(list(outside.iterdir()))

    def test_repeated_and_concurrent_submissions_are_locked(self):
        with Session() as session:
            run = next(p for p in (session.root / ".state").glob("install-onboarding.*") if p.name != "install-onboarding.lock")
            (run / "submit.lock").mkdir()
            self.assertEqual(session.request("save", URL)[:2], (409, {"code": "busy"}))
            (run / "submit.lock").rmdir()
            self.assertEqual(session.request("save", URL)[0], 200)
            self.assertEqual(session.request("skip", "")[:2], (409, {"code": "finished"}))
            self.assertEqual(session.wait(), 0)

    def test_incomplete_http_body_is_rejected(self):
        with Session() as session:
            with socket.create_connection(("127.0.0.1", session.port), timeout=12) as client:
                request = (f"POST /cgi-bin/setup/save HTTP/1.0\r\nHost: 127.0.0.1:{session.port}\r\n"
                           f"X-Setup-Token: {session.token}\r\nContent-Type: text/plain\r\nContent-Length: 30\r\n\r\nx")
                client.sendall(request.encode())
                client.shutdown(socket.SHUT_WR)
                response = b""
                while data := client.recv(4096):
                    response += data
                self.assertIn(b"400 Bad Request", response)
            self.assertFalse((session.root / ".config/sing-box/subscription.url").exists())

    def test_document_root_does_not_expose_secrets_or_handlers(self):
        with Session() as session:
            for path in ["/", "/app.js", "/style.css", "/handler.sh", "/result"]:
                with self.subTest(path=path):
                    conn = http.client.HTTPConnection("127.0.0.1", session.port, timeout=3)
                    conn.request("GET", path)
                    response = conn.getresponse()
                    body = response.read()
                    self.assertNotIn(session.token.encode(), body)
                    self.assertEqual(response.status, 200 if path in ["/", "/app.js", "/style.css"] else 404)
                    conn.close()

    def test_install_gates_and_no_tty_requirement(self):
        cases = [("fresh", {}, {}, True), ("gui", {"IS_TTY": "false"}, {}, True),
                 ("noninteractive", {"MAGICNET_NONINTERACTIVE": "1"}, {}, False),
                 ("optout", {"MAGICNET_INSTALL_ONBOARDING": "0"}, {}, False),
                 ("core-disabled", {"MAGIC_SINGBOX": "0"}, {}, False),
                 ("recovery", {"BOOTMODE": "false"}, {}, False),
                 ("url", {}, {"subscription.url": "https://old.example.test/sub\n"}, True),
                 ("local", {}, {"subscription.local": "/local/subscription.yaml\n"}, True),
                 ("standalone", {}, {"standalone-config": "", "config.json": "{}"}, True),
                 ("comments", {}, {"subscription.url": " # configure later\n\n"}, True)]
        for name, variables, files, expected in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                config = root / ".config/sing-box"
                config.mkdir(parents=True)
                for name, content in files.items():
                    (config / name).write_text(content)
                env = dict(os.environ, MODPATH=tmp, BOOTMODE="true")
                env.update(variables)
                script = '. "$1"; magicnet_onboarding_android_ready() { return 0; }; magicnet_onboarding_allowed'
                result = subprocess.run([BUSYBOX, "ash", "-c", script, "test", str(HELPER)], env=env)
                self.assertEqual(result.returncode == 0, expected)

    def test_installer_hook_order_and_no_unconditional_promotion(self):
        source = (MODULE / "customize.sh").read_text()
        self.assertGreater(source.index('magicnet_install_onboarding ||'), source.index('magicnet_install_config_template ||'))
        self.assertGreater(source.index('magicnet_install_onboarding ||'), source.index('set_perm "${MODPATH}/${_magicnet_entry}"'))
        self.assertNotIn('launch url "https://github.com', source)
        helper = HELPER.read_text()
        self.assertIn('import launcher', helper)
        self.assertIn('launch url "$1"', helper)
        self.assertNotIn('cli setup', helper)


if __name__ == "__main__":
    unittest.main(verbosity=2)
