// SPDX-License-Identifier: Apache-2.0
//
// The hi mark in SwiftUI, drawn from `HiMark` like the menu bar and the
// app icon. Letters take the foreground style.

import SwiftUI

public struct HiMarkView: View {
    public enum Style: Sendable {
        /// Letters in the foreground style; the dot blue while remembering.
        case brand
        /// Every part in the foreground style.
        case mono
    }

    public let style: Style
    public let state: HiMark.State

    public init(style: Style, state: HiMark.State) {
        self.style = style
        self.state = state
    }

    public var body: some View {
        ZStack {
            ForEach(HiMark.parts(for: state), id: \.self) { part in
                HiMarkShape(part: part).fill(fill(for: part))
            }
        }
        .aspectRatio(HiMark.inkBounds.width / HiMark.inkBounds.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func fill(for part: HiMark.Part) -> AnyShapeStyle {
        // Only the remembering picture has a solid dot, so only it turns blue.
        if part == .dot, style == .brand {
            let blue = HiMark.components(HiMark.dotRGB)
            return AnyShapeStyle(Color(.sRGB, red: blue.red, green: blue.green, blue: blue.blue))
        }
        let strength = HiMark.letterStrength(for: state)
        return strength < 1 ? AnyShapeStyle(ForegroundStyle().opacity(strength)) : AnyShapeStyle(ForegroundStyle())
    }
}

/// One part of the mark, placed the way the whole mark is: `HiMark.inkBounds`
/// fitted into the frame and centered, so the letters never move between
/// pictures.
struct HiMarkShape: Shape {
    let part: HiMark.Part

    func path(in rect: CGRect) -> Path {
        let box = HiMark.inkBounds
        let scale = min(rect.width / box.width, rect.height / box.height)
        var transform = CGAffineTransform(
            translationX: rect.midX - box.midX * scale,
            y: rect.midY - box.midY * scale
        ).scaledBy(x: scale, y: scale)
        let path = HiMark.path(for: part)
        return Path(path.copy(using: &transform) ?? path)
    }
}
