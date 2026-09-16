#!/usr/bin/env python3
"""Real Chromium tests. GitHub navigation is intercepted; no issues are submitted."""
from __future__ import annotations

import os
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from pathlib import Path
import shutil
import unittest
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "src/MagicNet/lib/magicnet/farewell/index.html"
OFFLINE = os.environ.get("MAGICNET_TEST_OFFLINE") == "1"


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass


class FarewellPageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(PAGE.parent)))
        cls.server_thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/index.html"
        cls.playwright = sync_playwright().start()
        chromium = os.environ.get("CHROMIUM_PATH") or shutil.which("chromium")
        options = {"executable_path": chromium} if chromium else {}
        cls.browser = cls.playwright.chromium.launch(headless=True, **options)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.browser.close()
        cls.playwright.stop()
        cls.server.shutdown()
        cls.server.server_close()
        cls.server_thread.join(timeout=3)

    def setUp(self) -> None:
        self.context = self.browser.new_context(locale="zh-CN", viewport={"width": 390, "height": 844})
        self.addCleanup(self.context.close)
        self.requests: list[str] = []
        self.errors: list[str] = []
        self.context.route("https://github.com/**", lambda route: route.fulfill(
            status=200, content_type="text/html", body="<title>Intercepted GitHub draft</title>"))
        self.context.on("request", lambda request: self.requests.append(request.url)
                        if request.url.startswith(("http://", "https://")) and not request.url.startswith(self.url.split("index.html")[0]) else None)
        self.page = self.context.new_page()
        self.page.on("pageerror", lambda error: self.errors.append(str(error)))
        self.load_fragment("v1.5.4+test")

    def load_fragment(self, fragment: str) -> None:
        if OFFLINE:
            self.page.close()
            self.page = self.context.new_page()
            self.page.on("pageerror", lambda error: self.errors.append(str(error)))
            self.page.evaluate("fragment => { location.hash = 'version=' + fragment; }", fragment)
            self.page.set_content(PAGE.read_text())
        else:
            self.page.goto(self.url + "#version=" + fragment)
            self.page.reload()

    def test_initial_page_is_local_and_not_submitted(self) -> None:
        self.assertEqual(self.requests, [])
        self.assertEqual(self.errors, [])
        self.assertTrue(self.page.locator("#choices").is_visible())
        self.assertFalse(self.page.locator("#thanks").is_visible())
        self.assertIn("v1.5.4+test", self.page.locator("#version").inner_text())

    def test_accept_opens_prefilled_draft_only_and_keeps_farewell_tab(self) -> None:
        if OFFLINE:
            self.skipTest("browser navigation blocked by host policy; run normal mode in CI")
        with self.context.expect_page() as opened:
            self.page.locator("#feedback").click()
        popup = opened.value
        popup.wait_for_load_state()
        url = urlparse(popup.url)
        self.assertEqual(url.netloc, "github.com")
        self.assertEqual(url.path, "/LIghtJUNction/MagicNet/issues/new")
        query = parse_qs(url.query)
        self.assertEqual(query["template"], ["uninstall_feedback.md"])
        self.assertIn("卸载反馈", query["title"][0])
        self.assertIn("MagicNet: v1.5.4+test", query["body"][0])
        self.assertNotIn("labels", query)
        self.assertNotIn("assignee", query)
        self.assertIsNone(popup.evaluate("window.opener"))
        self.assertFalse(self.page.is_closed())
        self.assertTrue(self.page.locator("#thanks").is_visible())
        self.assertTrue(self.page.locator("#retry").is_visible())
        self.assertFalse(self.page.locator("#choices").is_visible())
        self.assertEqual(self.errors, [])

    def test_draft_link_and_accept_state(self) -> None:
        href = self.page.locator("#feedback").get_attribute("href")
        self.assertIsNotNone(href)
        self.assertLess(len(href.encode()), 7000)
        query = parse_qs(urlparse(href).query)
        self.assertIn("MagicNet: v1.5.4+test", query["body"][0])
        self.assertEqual(self.page.locator("#feedback").get_attribute("target"), "_blank")
        self.assertIn("noreferrer", self.page.locator("#feedback").get_attribute("rel"))
        # Test the UI state separately from the navigation test above.
        self.page.locator("#feedback").evaluate("el => el.addEventListener('click', e => e.preventDefault())")
        self.page.locator("#feedback").click()
        self.assertTrue(self.page.locator("#thanks").is_visible())
        self.assertTrue(self.page.locator("#retry").is_visible())
        self.assertEqual(self.requests, [])

    def test_decline_does_not_navigate_or_close(self) -> None:
        self.page.locator("#decline").click()
        self.assertEqual(self.requests, [])
        self.assertEqual(len(self.context.pages), 1)
        self.assertTrue(self.page.locator("#thanks").is_visible())
        self.assertFalse(self.page.locator("#retry").is_visible())
        self.assertIn("没关系", self.page.locator("#status").inner_text())
        self.assertFalse(self.page.is_closed())

    def test_language_switch_preserves_decline(self) -> None:
        self.page.locator("#decline").click()
        for language, phrase in [("en", "No problem"), ("ru", "Хорошо"), ("zh", "没关系")]:
            self.page.locator("#language").select_option(language)
            self.assertIn(phrase, self.page.locator("#status").inner_text())
            self.assertFalse(self.page.locator("#choices").is_visible())
        self.assertEqual(self.requests, [])

    def test_fragment_is_never_html_or_code(self) -> None:
        for value in ("%3Cimg%20src=x%20onerror=alert(1)%3E", "%E0%A4%A", "x" * 65):
            self.load_fragment(value)
            self.assertIn("未知", self.page.locator("#version").inner_text())
            self.assertEqual(self.page.locator("img").count(), 0)
        self.assertEqual(self.errors, [])
        self.assertEqual(self.requests, [])

    def test_mobile_dark_light_and_language_layouts(self) -> None:
        destination = os.environ.get("MAGICNET_TEST_SCREENSHOTS")
        if destination:
            Path(destination).mkdir(parents=True, exist_ok=True)
        for width in (320, 390, 768):
            self.page.set_viewport_size({"width": width, "height": 844})
            for language in ("zh", "en", "ru"):
                self.page.locator("#language").select_option(language)
                for theme in ("light", "dark"):
                    self.page.emulate_media(color_scheme=theme, reduced_motion="reduce")
                    self.assertTrue(self.page.evaluate(
                        "document.documentElement.scrollWidth <= window.innerWidth"),
                        f"overflow: {width}/{language}/{theme}")
                    for selector in ("#feedback", "#decline"):
                        box = self.page.locator(selector).bounding_box()
                        self.assertIsNotNone(box)
                        self.assertGreaterEqual(box["height"], 48)
                    if destination and width == 390 and language == "zh":
                        self.page.screenshot(path=str(Path(destination) / f"magicnet-farewell-{theme}.png"), full_page=True)
        self.assertEqual(self.errors, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
