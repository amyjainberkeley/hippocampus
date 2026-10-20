// SPDX-License-Identifier: Apache-2.0
//
// DemoMemoryPreferencesSection.swift — Demo Memory in Preferences › About
// (SPEC-DELTA 6).

import HippocampusKit
import SwiftUI

/// Use Demo Memory… and Leave Demo Memory in Preferences › About, beside the
/// hi menu's Option-click (SPEC-DELTA 6). Hidden from ordinary use: a few
/// quiet lines under the version, and no row in the window's sidebar.
/// Nothing shows until the app has attached Demo Memory.
struct DemoMemoryPreferencesSection: View {
    @Environment(\.demoMemoryPreview) private var preview

    var body: some View {
        if let controller = preview ?? DemoMemory.controller {
            DemoMemoryPreferencesRows(controller: controller)
        }
    }
}

private struct DemoMemoryPreferencesRows: View {
    @ObservedObject var controller: DemoMemoryController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DemoCopy.preferencesTitle)
                .font(.system(size: 13, weight: .semibold))
            Text(caption)
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: PreferencesStyle.controlSpacing) {
                Button(buttonTitle, action: act)
                    .disabled(!canAct)
                if controller.phase == .making || controller.phase == .leaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            .padding(.top, 2)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }

    private var caption: String {
        switch controller.phase {
        case .off: DemoCopy.preferencesOff
        case .making: DemoCopy.preferencesMaking
        case .on: DemoCopy.preferencesOn
        case .leaving: DemoCopy.preferencesLeaving
        }
    }

    private var buttonTitle: String {
        switch controller.phase {
        case .off: DemoCopy.use
        case .making: DemoCopy.making
        case .on: DemoCopy.leave
        case .leaving: DemoCopy.leaving
        }
    }

    private var canAct: Bool {
        switch controller.phase {
        case .off: !controller.isSwitching
        case .on: true
        case .making, .leaving: false
        }
    }

    private func act() {
        switch controller.phase {
        case .off: controller.requestUse()
        case .on: controller.requestLeave()
        case .making, .leaving: break
        }
    }
}

private struct DemoMemoryPreviewKey: EnvironmentKey {
    static let defaultValue: DemoMemoryController? = nil
}

extension EnvironmentValues {
    /// A controller to show instead of the app's, for pictures.
    var demoMemoryPreview: DemoMemoryController? {
        get { self[DemoMemoryPreviewKey.self] }
        set { self[DemoMemoryPreviewKey.self] = newValue }
    }
}
