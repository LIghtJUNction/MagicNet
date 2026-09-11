#!/usr/bin/env python3
"""Installer guards and real BusyBox HTTP/CGI regressions (no Internet or root).

Android intents are mocked. The actual kamfw import loader is extracted rather
than loading its Android runtime; the real form/launcher/CGI files are executed.
"""
from __future__ import annotations

import atexit
import http.client
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import zipfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "src/MagicNet"
# Reproduce the install-time overlay over the checked-out framework. Never edit
# the submodule checkout, and retain its real import loader for these tests.
FW_STAGE = tempfile.TemporaryDirectory(prefix="magicnet-kamfw-")
atexit.register(FW_STAGE.cleanup)
FW = Path(FW_STAGE.name) / "kamfw"
shutil.copytree(MODULE / "lib/kamfw", FW, ignore=shutil.ignore_patterns(".git"))
for relative in ("launcher.sh", "web_form.sh", "web_form/handler.sh"):
    destination = FW / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(MODULE / "lib/kamfw-overlay" / relative, destination)
ASSETS = MODULE / "lib/magicnet/setup"
BB = shutil.which("busybox")
if not BB:
    raise SystemExit("busybox with httpd/CGI is required (install busybox-static)")
RC = (FW / ".kamfwrc").read_text()
MATCH = re.search(r"(_kamfw_load\s*\(\)\s*\{.*?\n\})\s*\n", RC, re.S)
if not MATCH:
    raise SystemExit("kamfw import loader not found")
BOOTSTRAP = f"""
KAMFW_DIR={shlex.quote(str(FW))}
KAM_MODULES=''
print() {{ printf '%s\\n' "$1"; }}
{MATCH.group(1)}
import() {{ _kamfw_load "$@"; }}
set_i18n() {{ :; }}
i18n() {{ printf '%s\\n' "$1"; }}
t() {{ cat; }}
info() {{ print "$1"; }}
warn() {{ print "$1"; }}
success() {{ print "$1"; }}
"""


def run_shell(script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([BB, "ash", "-c", BOOTSTRAP + script], env=env,
                          capture_output=True, text=True, timeout=15, check=False)


class Session:
    def __init__(self, ttl: int = 25, initial: bytes | None = None,
                 extra: str = "", start: bool = True):
        self.tmp = tempfile.TemporaryDirectory(prefix="magicnet-form-")
        self.base = Path(self.tmp.name)
        self.out = self.base / "subscription.url"
        if initial is not None:
            self.out.write_bytes(initial)
        bindir = self.base / "bin"
        bindir.mkdir()
        (bindir / "am").write_text('#!/bin/sh\nif [ "$1" = get-current-user ]; then printf "10\\n"; exit 0; fi\nprintf "%s\\n" "$@" >>"$LAUNCH_LOG"\nexit "${AM_STATUS:-0}"\n')
        (bindir / "cmd").write_text('#!/bin/sh\nif [ "$1" = role ]; then printf "%s\\n" "${BROWSER_PACKAGE:-org.example.browser}"; fi\nexit 0\n')
        for p in bindir.iterdir():
            p.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}",
                        LAUNCH_LOG=str(self.base / "launch.log"),
                        KAM_WEB_FORM_BUSYBOX=BB)
        self.script = BOOTSTRAP + f"""
import web_form
web_form_ready() {{ print "$1"; }}
trap 'printf preserved > {shlex.quote(str(self.base / 'parent-exit'))}' 0
{extra}
status=0
web_form_collect_url {shlex.quote(str(ASSETS))} {shlex.quote(str(self.out))} {ttl} || status=$?
exit "$status"
"""
        self.process = None
        self.url = ""
        self.origin = ""
        self.token = ""
        if start:
            self.start()

    def start(self):
        self.process = subprocess.Popen([BB, "ash", "-c", self.script], env=self.env,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, start_new_session=True)
        return self

    def ready(self):
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                if selector.select(.2):
                    line = self.process.stdout.readline().strip()
                    if line.startswith("http://127.0.0.1:"):
                        self.url = line
                        parsed = urlsplit(line)
                        self.origin = f"http://{parsed.netloc}"
                        self.token = parsed.fragment
                        return self
                if self.process.poll() is not None:
                    break
            raise AssertionError(f"form did not start: {self.process.communicate(timeout=2)!r}")
        finally:
            selector.close()

    def request(self, path="/save", body: bytes | str = b"https://example.invalid/sub?key=test",
                method="POST", headers=None, token=True):
        parsed = urlsplit(self.origin)
        h = {"Content-Type": "text/plain;charset=UTF-8"}
        if token:
            h["X-Setup-Token"] = self.token
        if headers:
            h.update(headers)
        connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=10)
        try:
            if isinstance(body, str):
                body = body.encode()
            connection.request(method, "/cgi-bin/api" + path, body=body, headers=h)
            response = connection.getresponse()
            return response.status, response.read().decode(), dict(response.getheaders())
        finally:
            connection.close()

    def finish(self, expected=0):
        stdout, stderr = self.process.communicate(timeout=12)
        assert self.process.returncode == expected, (self.process.returncode, stdout, stderr)
        assert not list(self.base.glob(".web-form.*")), "temporary webroot leaked"
        assert not Path(str(self.out) + ".web-form.lock").exists(), "session lock leaked"
        assert (self.base / "parent-exit").read_text() == "preserved", "parent EXIT trap replaced"
        if self.origin:
            parsed = urlsplit(self.origin)
            with socket.socket() as sock:
                sock.settimeout(1)
                assert sock.connect_ex((parsed.hostname, parsed.port)) != 0, "listener leaked"
        return stdout, stderr

    def close(self):
        if self.process and self.process.poll() is None:
            try:
                if self.url:
                    self.request("/skip", b"")
                self.process.communicate(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.communicate()
        self.tmp.cleanup()


class HttpTests(unittest.TestCase):
    def session(self, **kwargs):
        item = Session(**kwargs)
        self.addCleanup(item.close)
        return item

    def test_strict_https_policy(self):
        session = self.session(extra="KAM_WEB_FORM_HTTPS_ONLY=1").ready()
        for value in (b"http://example.test/sub", b"https://example.test/sub?mail=a@b"):
            self.assertEqual(session.request(body=value)[0], 400)
        code, body, _ = session.request(body=b"https://example.test/sub?mail=a%40b")
        self.assertEqual((code, body), (200, "saved\n"))
        session.finish()

    def test_save_exact_special_characters_and_private_permissions(self):
        s = self.session().ready()
        value = "https://example.invalid/sub?t=a%2Bb+c&x=$('quoted');echo#测试"
        code, text, headers = s.request(body=value)
        self.assertEqual((code, text.strip()), (200, "saved"))
        # Persistence must precede the HTTP success response.
        self.assertEqual(s.out.read_text(), value + "\n")
        self.assertEqual(s.out.stat().st_mode & 0o777, 0o600)
        self.assertEqual(headers["Cache-Control"], "no-store")
        stdout, stderr = s.finish()
        self.assertNotIn(value, stdout + stderr)
        launch = (s.base / "launch.log").read_text()
        self.assertIn("current\n", launch)
        self.assertIn("android.intent.category.BROWSABLE", launch)
        self.assertIn("org.example.browser", launch)
        self.assertNotIn("com.android.chrome", launch)

    def test_invalid_input_and_request_guards(self):
        s = self.session().ready()
        cases = [
            ({"token": False}, 403),
            ({"headers": {"X-Setup-Token": "0" * 48}}, 403),
            ({"headers": {"Host": "evil.invalid"}}, 403),
            ({"headers": {"Origin": "https://evil.invalid"}}, 403),
            ({"method": "GET"}, 405), ({"method": "OPTIONS"}, 405),
            ({"path": "/unknown"}, 404),
            ({"headers": {"Content-Type": "application/json"}}, 415),
            ({"body": b""}, 400), ({"body": b"ftp://example.invalid"}, 400),
            ({"body": b"javascript:alert(1)"}, 400), ({"body": b"https:///path"}, 400),
            ({"body": b"https://user:password@example.invalid"}, 400),
            ({"body": b"https://example.invalid/a b"}, 400),
            ({"body": b"https://example.invalid/a\n"}, 400),
            ({"body": b"https://example.invalid/a\x00b"}, 400),
            ({"body": b"https://example.invalid/a\x7f"}, 400),
            ({"body": b"https://example.invalid/" + b"x" * 8192}, 413),
        ]
        for args, expected in cases:
            with self.subTest(args=args):
                self.assertEqual(s.request(**args)[0], expected)
                self.assertFalse(s.out.exists())
        self.assertEqual(s.request("/health", method="GET", body=b"")[0], 200)
        s.request("/skip", b"")
        s.finish(2)

    def test_public_assets_do_not_expose_token_or_private_files(self):
        s = self.session().ready()
        parsed = urlsplit(s.origin)
        connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=5)
        for path in ("/", "/style.css", "/app.js"):
            connection.request("GET", path)
            response = connection.getresponse()
            body = response.read()
            self.assertEqual(response.status, 200)
            self.assertNotIn(s.token.encode(), body)
        for path in ("/subscription.url", "/handler.sh", "/library.sh"):
            connection.request("GET", path)
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 404)
        connection.close()
        # /proc shows the listener bound to loopback, not 0.0.0.0.
        port = f"{parsed.port:04X}"
        rows = [line.split() for line in Path('/proc/net/tcp').read_text().splitlines()[1:]]
        self.assertTrue(any(row[1] == f"0100007F:{port}" and row[3] == "0A" for row in rows))
        s.request("/skip", b"")
        s.finish(2)

    def test_skip_preserves_empty_input(self):
        s = self.session(initial=b"").ready()
        self.assertEqual(s.request("/skip", b"")[1].strip(), "skipped")
        s.finish(2)
        self.assertEqual(s.out.read_bytes(), b"")

    def test_existing_subscription_never_launches(self):
        s = self.session(initial=b"https://old.invalid/sub\n")
        s.finish(5)
        self.assertEqual(s.out.read_text(), "https://old.invalid/sub\n")
        self.assertFalse((s.base / "launch.log").exists())

    def test_concurrently_supplied_input_wins(self):
        s = self.session().ready()
        s.out.write_text("https://manual.invalid/sub\n")
        self.assertEqual(s.request()[1].strip(), "existing")
        s.finish(5)
        self.assertEqual(s.out.read_text(), "https://manual.invalid/sub\n")

    def test_replayed_submission_cannot_overwrite(self):
        s = self.session().ready()
        self.assertEqual(s.request()[0], 200)
        self.assertEqual(s.request(body="https://other.invalid/sub")[0], 409)
        s.finish()
        self.assertEqual(s.out.read_text(), "https://example.invalid/sub?key=test\n")

    def test_two_collectors_cannot_own_same_destination(self):
        s = self.session().ready()
        duplicate = subprocess.run([BB, "ash", "-c", s.script], env=s.env,
                                   capture_output=True, text=True, timeout=5)
        self.assertEqual(duplicate.returncode, 4)
        s.request("/skip", b"")
        s.finish(2)

    def test_timeout_reaps_service_and_keeps_parent_exit_handler(self):
        s = self.session(ttl=5).ready()
        s.finish(3)
        self.assertFalse(s.out.exists())

    def test_signal_cleanup(self):
        s = self.session().ready()
        os.killpg(s.process.pid, signal.SIGTERM)
        s.process.communicate(timeout=5)
        self.assertFalse(list(s.base.glob(".web-form.*")))
        self.assertFalse(Path(str(s.out) + ".web-form.lock").exists())

    def test_bad_busybox_and_missing_assets_fail_without_launch(self):
        for suffix in ("KAM_WEB_FORM_BUSYBOX=/not-a-busybox",):
            with self.subTest(case=suffix):
                s = self.session(extra=suffix)
                s.finish(4)
                self.assertFalse((s.base / "launch.log").exists())
        s = self.session(start=False)
        s.script = s.script.replace(shlex.quote(str(ASSETS)), "/missing-assets")
        s.start().finish(4)

    def test_symlink_input_and_ancestor_are_rejected(self):
        for ancestor in (False, True):
            with self.subTest(ancestor=ancestor):
                s = self.session(start=False)
                target = s.base / "other"
                target.mkdir()
                if ancestor:
                    link = s.base / "alias"
                    link.symlink_to(target, target_is_directory=True)
                    s.script = s.script.replace(str(s.out), str(link / "subscription.url"))
                else:
                    s.out.symlink_to(target / "secret")
                s.start().finish(4)
                self.assertEqual(list(target.iterdir()), [])

    def test_default_browser_fallback_and_real_exit_status(self):
        s = self.session(start=False)
        s.env["BROWSER_PACKAGE"] = "not a package"
        result = run_shell('import launcher; launch browser "https://example.invalid"', s.env)
        self.assertEqual(result.returncode, 0)
        launch = (s.base / "launch.log").read_text()
        self.assertNotIn("-p\n", launch)
        s.env["AM_STATUS"] = "7"
        result = run_shell('import launcher; launch url "https://example.invalid"', s.env)
        self.assertEqual(result.returncode, 7)
        result = run_shell('import launcher; launch browser "intent://anything"', s.env)
        self.assertEqual(result.returncode, 2)


class InstallerTests(unittest.TestCase):
    def test_bootstrap_extracts_assets_and_applies_framework_overlay(self):
        with tempfile.TemporaryDirectory() as name:
            base = Path(name)
            archive = base / "module.zip"
            destination = base / "installed"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("lib/kamfw/.kamfwrc", ":\n")
                bundle.writestr("lib/kamfw/launcher.sh", "# upstream launcher\n")
                bundle.writestr("lib/magicnet/i18n.sh", ":\n")
                for relative in ("lib/kamfw-overlay/launcher.sh", "lib/kamfw-overlay/web_form.sh",
                                 "lib/kamfw-overlay/web_form/handler.sh", "lib/magicnet/install_setup.sh",
                                 "lib/magicnet/setup/index.html", "lib/magicnet/setup/style.css",
                                 "lib/magicnet/setup/app.js"):
                    bundle.write(MODULE / relative, relative)
            bootstrap = (MODULE / "customize.sh").read_text().split("import __customize__", 1)[0]
            script = "abort() { printf '%s\\n' \"$1\" >&2; exit 1; }\n" + bootstrap
            result = subprocess.run([BB, "ash", "-c", script], capture_output=True, text=True,
                                    env=dict(os.environ, ZIPFILE=str(archive), MODPATH=str(destination)),
                                    timeout=10, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            for relative in ("launcher.sh", "web_form.sh", "web_form/handler.sh"):
                self.assertEqual((destination / "lib/kamfw" / relative).read_bytes(),
                                 (MODULE / "lib/kamfw-overlay" / relative).read_bytes())
            for relative in ("install_setup.sh", "setup/index.html", "setup/style.css", "setup/app.js"):
                self.assertTrue((destination / "lib/magicnet" / relative).is_file())

    def test_install_guards_and_non_tty_gui(self):
        cases = [
            ({"BOOTMODE": "false"}, None, False),
            ({"MAGICNET_NONINTERACTIVE": "1"}, None, False),
            ({"MAGICNET_SETUP": "0"}, None, False),
            ({"MAGIC_SINGBOX": "0"}, None, False),
            ({}, "subscription.url", False), ({}, "subscription.local", False),
            ({}, "standalone-config", False), ({}, None, True),
        ]
        for overrides, existing, expected in cases:
            with self.subTest(overrides=overrides, existing=existing):
                with tempfile.TemporaryDirectory() as name:
                    base = Path(name)
                    config = base / ".config/sing-box"
                    config.mkdir(parents=True)
                    if existing:
                        (config / existing).write_text("" if existing == "standalone-config" else "preserve-me\n")
                    calls = base / "called"
                    env = dict(os.environ, MODPATH=str(base), BOOTMODE="true", IS_TTY="false")
                    env.update(overrides)
                    script = f'''
am() {{ :; }}
import() {{ [ "$1" = web_form ]; }}
web_form_collect_url() {{ printf called >{shlex.quote(str(calls))}; return 2; }}
. {shlex.quote(str(MODULE / 'lib/magicnet/install_setup.sh'))}
magicnet_install_setup
'''
                    result = run_shell(script, env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(calls.exists(), expected)
                    if existing != "standalone-config" and existing:
                        self.assertEqual((config / existing).read_text(), "preserve-me\n")

    def test_customize_hook_runs_after_restore_and_template(self):
        source = (MODULE / "customize.sh").read_text()
        hook = source.rindex("magicnet_install_setup")
        self.assertGreater(hook, source.index('magicnet_install_config_template ||'))
        self.assertGreater(hook, source.index('magicnet_cleanup_install_backup ||'))
        self.assertNotIn('launch url "https://github.com', source)

    def test_all_assets_are_offline_and_links_are_opt_in(self):
        html = (ASSETS / "index.html").read_text()
        self.assertIn('name="referrer" content="no-referrer"', html)
        self.assertIn("form-action 'none'", html)
        for tag in re.findall(r'<a\b[^>]*>', html):
            self.assertIn('target="_blank"', tag)
            self.assertIn('rel="noopener noreferrer"', tag)
            self.assertRegex(tag, r'href="https://')
        self.assertNotRegex(html, r'<(?:script|link)[^>]+(?:src|href)="https?://')
        self.assertIn('prefers-color-scheme:dark', (ASSETS / 'style.css').read_text())
        self.assertIn('prefers-reduced-motion:reduce', (ASSETS / 'style.css').read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
