"""Headless composition contracts; native sizing/focus proof runs at integration."""

from pathlib import Path
import re
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "Sources" / "RecallUI"


class EvidencePresentationTests(unittest.TestCase):
    def test_command_palette_defers_focus_until_its_field_is_mounted(self):
        source = (SOURCE / "ActionPanel" / "ActionPanel.swift").read_text().split(
            "private var inputField", 1)[0]
        self.assertNotIn(".onAppear { viewModel.reset(); isFieldFocused = true }", source)
        self.assertIn("await Task.yield()", source)
        self.assertIn("!Task.isCancelled", source)

    def test_root_and_overlay_host_do_not_observe_contextual_command_changes(self):
        root = (SOURCE / "MCIRecallApp.swift").read_text()
        self.assertNotIn("@ObservedObject private var actionPanelRegistry", root)
        self.assertIn("actionPanelRegistry.$isHelpVisible", root)
        host = (SOURCE / "ActionPanel" / "ActionPanel.swift").read_text().split(
            "struct ActionPanelHost: ViewModifier", 1)[1]
        self.assertNotIn("@ObservedObject", host)
        self.assertIn("registry.$isVisible", host)
        self.assertIn(".removeDuplicates()", host)
        self.assertIn(".receive(on: RunLoop.main)", host)

    def test_detail_header_does_not_present_rank_as_a_percentage(self):
        source = (SOURCE / "DetailPaneView.swift").read_text()
        self.assertFalse("scoreString(" in source, "Detail header must not turn BM25 into a percentage")

    def test_empty_search_uses_a_scrollable_viewport_and_a_bounded_heading(self):
        source = (SOURCE / "SearchView.swift").read_text()
        self.assertTrue("EvidenceStateViewport {" in source, "Search status must stay within the window")
        self.assertFalse("MCIEmptyState.noSearchHits(query:" in source,
                         "An arbitrary query must not become an unbounded empty-state heading")
        viewport = (SOURCE / "AdaptiveEvidencePanes.swift").read_text()
        self.assertTrue("struct EvidenceStateViewport<" in viewport)
        self.assertTrue("ScrollView(.vertical)" in viewport)
        self.assertFalse(".frame(minHeight: geometry.size.height)" in viewport,
                         "Scroll content must not feed the viewport's height back into its minimum")

    def test_search_does_not_observe_command_registration_during_detail_teardown(self):
        source = (SOURCE / "SearchView.swift").read_text()
        self.assertFalse("@ObservedObject private var actionPanelRegistry" in source,
                         "Detail teardown publishes commands; Search only needs the refresh flag")
        self.assertTrue("ActionPanelRegistry.shared.$isRefreshing" in source)
        self.assertTrue(".removeDuplicates()" in source)
        self.assertTrue(".receive(on: RunLoop.main)" in source)

    def test_search_shell_keeps_toolbar_and_content_inside_one_stable_viewport(self):
        source = (SOURCE / "SearchView.swift").read_text()
        self.assertIsNotNone(re.search(
            r"var body: some View\s*\{\s*GeometryReader \{ geometry in\s*VStack", source))
        self.assertTrue(
            ".frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)" in source)

    def test_compact_focus_handoffs_are_deferred_and_cancelled_on_removal(self):
        source = (SOURCE / "AdaptiveEvidencePanes.swift").read_text()
        self.assertFalse(".onAppear { isBackFocused = true }" in source)
        self.assertTrue(".task(id: primaryFocusRequest)" in source)
        self.assertGreaterEqual(source.count("await Task.yield()"), 2)
        self.assertGreaterEqual(source.count("!Task.isCancelled"), 2)

    def test_timeline_and_episode_statuses_use_the_same_bounded_viewport(self):
        for name in ("TimelineView.swift", "EpisodesView.swift"):
            with self.subTest(destination=name):
                source = (SOURCE / name).read_text()
                self.assertEqual(source.count("EvidenceStateViewport {"), 3,
                                 "Error, loading, and empty states must all scroll within the pane")

    def test_hit_rows_do_not_present_retrieval_scores_as_percentages(self):
        row = (SOURCE / "HitRow.swift").read_text()
        self.assertNotIn("scoreString(", row)
        self.assertNotRegex(row, r"hit\.score|\.percent|%[.\d]*f%%")
        self.assertIn("Formatters.matchReason(hit.source)", row)

    def test_destinations_use_adaptive_panes_without_competing_minimum_widths(self):
        for name in ("SearchView.swift", "TimelineView.swift", "EpisodesView.swift"):
            with self.subTest(destination=name):
                source = (SOURCE / name).read_text()
                self.assertIn("AdaptiveEvidencePanes(", source)
                self.assertNotRegex(source, r"\.frame\(minWidth:\s*(280|300)")

    def test_search_filters_scroll_instead_of_enlarging_the_window(self):
        source = (SOURCE / "SearchView.swift").read_text()
        self.assertRegex(source, r"ScrollView\(\.horizontal\)\s*\{\s*FilterPillsView\(")
        self.assertTrue(".frame(height: 72)" in source, "The two-row filter strip needs bounded height")
        self.assertFalse(".fixedSize(horizontal: false, vertical: true)" in source,
                         "A horizontal scroll view must not derive the window's height")

    def test_only_related_mode_is_disabled_for_unsupported_filters(self):
        source = (SOURCE / "SearchView.swift").read_text()
        self.assertIsNotNone(re.search(
            r'Text\("Related"\)\.tag\(SearchMode\.related\)\s*'
            r'\.selectionDisabled\(viewModel\.hasUnsupportedRelatedFilters\)', source))
        self.assertIsNone(re.search(
            r'Text\("Text"\)\.tag\(SearchMode\.text\)\s*\.(selectionDisabled|disabled)', source))

    def test_unsupported_related_filters_are_not_reported_as_no_matches(self):
        source = (SOURCE / "SearchView.swift").read_text()
        status = source.split("private var searchStatus: some View", 1)[1]
        self.assertTrue("viewModel.filterLimitationMessage" in status)
        self.assertTrue("viewModel.hasUnsupportedRelatedFilters" in status)
        self.assertLess(status.index("viewModel.filterLimitationMessage"),
                        status.index('"No matching memories"'))
        self.assertTrue('"Related search unavailable"' in status)
        self.assertTrue("description: Text(message)" in status)

    def test_supported_related_filter_warning_is_visible_with_results(self):
        source = (SOURCE / "SearchView.swift").read_text()
        content = source.split("private var content: some View", 1)[1].split(
            "private var searchStatus: some View", 1)[0]
        self.assertTrue("viewModel.filterLimitationMessage" in content)
        self.assertTrue("!viewModel.hasUnsupportedRelatedFilters" in content)
        self.assertTrue("Text(message)" in content)
        self.assertTrue(".help(message)" in content)
        self.assertLess(content.index("Text(message)"), content.index("searchResults"))

    def test_filter_limitations_do_not_replace_text_search_or_empty_query_browsing(self):
        source = (SOURCE / "SearchView.swift").read_text()
        branches = re.findall(
            r"if let message = viewModel\.filterLimitationMessage,([^\{]+)\{", source)
        self.assertEqual(len(branches), 2)
        for condition in branches:
            self.assertTrue("viewModel.mode == .related" in condition)
            self.assertTrue(
                "!viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty" in condition)

    def test_compact_panes_have_back_escape_and_keyboard_focus_return(self):
        path = SOURCE / "AdaptiveEvidencePanes.swift"
        self.assertTrue(path.exists(), "Compact navigation needs a shared pane container")
        source = path.read_text()
        self.assertIn('Label(backLabel, systemImage: "chevron.left")', source)
        self.assertIn(".help(backLabel)", source)
        self.assertIn(".onKeyPress(.escape", source)
        self.assertIn(".focused($isPrimaryFocused)", source)
        self.assertRegex(source, r"onDismissDetail\(\)\s*primaryFocusRequest \+= 1")
        self.assertNotIn(".focusEffectDisabled(", source)

    def test_split_is_only_created_when_the_available_width_can_fit_both_panes(self):
        path = SOURCE / "AdaptiveEvidencePanes.swift"
        self.assertTrue(path.exists(), "A fixed pair of panes must not set the window's minimum")
        source = path.read_text()
        self.assertIn("GeometryReader { geometry in", source)
        self.assertRegex(source, r"if geometry\.size\.width >= minimumSplitWidth\s*\{\s*HSplitView")
        self.assertIn(".frame(width: geometry.size.width, height: geometry.size.height)", source)
        threshold = re.search(r"minimumSplitWidth: CGFloat = (\d+)", source)
        self.assertIsNotNone(threshold)
        self.assertGreaterEqual(int(threshold.group(1)), 300 + 360 + 1)

    def test_existing_search_and_timeline_keyboard_selection_is_retained(self):
        for name in ("SearchView.swift", "TimelineView.swift"):
            with self.subTest(destination=name):
                source = (SOURCE / name).read_text()
                self.assertIn("List(selection: $viewModel.selectedHitId)", source)
                self.assertIn(".onKeyPress(.return", source)
                self.assertIn("viewModel.focusDetail()", source)
                self.assertIn("viewModel.dismissDetail()", source)
                self.assertIn(".onChange(of: viewModel.selectedHitId)", source)


if __name__ == "__main__":
    unittest.main()
