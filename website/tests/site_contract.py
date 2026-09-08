"""Rendered-site contract. Run against the local preview, not personal memory."""

import os
import unittest
from html.parser import HTMLParser
from urllib.request import urlopen


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.links = []
        self.images = []
        self.text = []
        self.headings = []
        self.heading = None
        self.hidden = 0
        with urlopen(BASE + path, timeout=30) as response:
            self.feed(response.read().decode("utf-8"))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ("script", "style"):
            self.hidden += 1
        if tag == "a":
            self.links.append(attrs.get("href", ""))
        if tag == "img":
            self.images.append(attrs)
        if tag in ("h1", "h2", "h3"):
            self.heading = [tag, ""]

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.hidden -= 1
        if self.heading and self.heading[0] == tag:
            self.headings.append(tuple(self.heading))
            self.heading = None

    def handle_data(self, text):
        if not self.hidden:
            self.text.append(text)
            if self.heading:
                self.heading[1] += text


BASE = os.environ.get("HIPPOCAMPUS_SITE_TEST_URL", "http://localhost:4177").rstrip("/")


class SiteContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.home = Page("/")

    def test_literal_product_identity_and_purpose(self):
        self.assertEqual([text for tag, text in self.home.headings if tag == "h1"], ["Hippocampus"])
        self.assertIn("Memory for your Mac.", self.home.text)

    def test_home_has_no_sales_process_or_unproven_automation_claim(self):
        text = " ".join(self.home.text)
        for old_copy in ("Inspectable origins", "What your memory gives you", "One memory, two ways", "Never explain yourself", "23%"):
            self.assertNotIn(old_copy, text)

    def test_product_evidence_is_a_real_app_example_with_disclosure(self):
        images = [image for image in self.home.images if image.get("src", "").startswith("/product-")]
        self.assertTrue(images)
        self.assertTrue(all("synthetic" in image.get("alt", "").lower() for image in images))
        self.assertIn("App screenshots use synthetic work data.", self.home.text)

    def test_onboarding_privacy_and_source_remain_reachable(self):
        for route in ("/download", "/setup", "/privacy"):
            self.assertIn(route, self.home.links)
            self.assertTrue(Page(route).headings)
        self.assertIn("https://github.com/amyjainberkeley/hippocampus/tree/codex/hippocampus-v1", self.home.links)

    def test_download_is_not_presented_as_a_qualified_public_release(self):
        page = Page("/download")
        self.assertIn("Public download is not ready yet.", page.text)
        self.assertFalse(any(link.endswith(".dmg") for link in page.links))
        self.assertNotIn("Website artwork is illustrative", " ".join(page.text))

    def test_setup_uses_current_daily_review_and_reviewed_handoff(self):
        text = " ".join(Page("/setup").text)
        self.assertIn("Daily review", text)
        self.assertIn("select Handoff", text)
        self.assertNotIn("Return to Now", text)


if __name__ == "__main__":
    unittest.main()
