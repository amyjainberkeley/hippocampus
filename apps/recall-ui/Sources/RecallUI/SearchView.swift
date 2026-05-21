// SearchView.swift — search bar + result list. Routes through
// SearchViewModel; the StubBrainReader supplies canned data in P3.9a.

import SwiftUI
import RecallUIKit

struct SearchView: View {
    @StateObject var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "Search everything you've seen…",
                text: $viewModel.query
            )
            .textFieldStyle(.plain)
            .onSubmit {
                Task { await viewModel.runSearch() }
            }
            if viewModel.isSearching {
                ProgressView().controlSize(.small)
            }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let err = viewModel.errorMessage {
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.triangle",
                description: Text(err)
            )
        } else if viewModel.query.isEmpty {
            ContentUnavailableView(
                "Type to search your brain",
                systemImage: "brain",
                description: Text(
                    "Lexical + semantic recall across everything MCI has captured."
                )
            )
        } else if viewModel.hits.isEmpty && !viewModel.isSearching {
            ContentUnavailableView(
                "No matches",
                systemImage: "tray",
                description: Text("Try different words or a broader query.")
            )
        } else {
            List(viewModel.hits) { hit in
                HitRow(hit: hit)
            }
            .listStyle(.inset)
        }
    }
}
