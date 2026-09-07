"""Picker wiring contracts; Swift behavior tests run under the reserved build lock."""

from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "Sources" / "RecallUI"


class AppFilterSelectionPresentationTests(unittest.TestCase):
    def test_inline_and_overflow_options_share_the_model_selection_guard(self):
        source = (SOURCE / "FilterPillsView.swift").read_text()
        inline = source.split("private func appPill", 1)[1].split(
            "private var overflowAppsMenu", 1)[0]
        overflow = source.split("private var overflowAppsMenu", 1)[1].split(
            "private var hasUrlPill", 1)[0]
        for control in (inline, overflow):
            with self.subTest(control=control[:40]):
                self.assertIn(".disabled(!filters.canToggleApp(app.appBundleId))", control)
                self.assertIn(".help(filters.appSelectionHelp)", control)
                self.assertIn(".accessibilityHint(filters.appSelectionHelp)", control)
        self.assertIn("ForEach(extraSelectedApps", source,
                      "Restored selections absent from observed apps must remain deselectable")

    def test_cap_and_restoration_validation_are_visible_before_app_options(self):
        source = (SOURCE / "FilterPillsView.swift").read_text()
        row = source.split("private var appAndPredicateRow", 1)[1].split(
            "private var inlineApps", 1)[0]
        self.assertIn("appSelectionStatus", row)
        self.assertLess(row.index("appSelectionStatus"), row.index("ForEach(inlineApps)"))
        self.assertIn("private var appSelectionStatus", source)
        status = source.split("private var appSelectionStatus", 1)[1].split(
            "private func appPill", 1)[0]
        self.assertIn("filters.hasReachedAppSelectionLimit", status)
        self.assertIn("filters.appSelectionValidationMessage", status)
        self.assertIn(".accessibilityLabel(", status)
        self.assertIn(".accessibilityHint(filters.appSelectionHelp)", status)
        self.assertIn(".help(filters.appSelectionHelp)", status)
        self.assertIn("deselect", status.lower())


if __name__ == "__main__":
    unittest.main()
