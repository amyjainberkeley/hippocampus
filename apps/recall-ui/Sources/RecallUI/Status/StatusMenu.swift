import AppKit
import RecallUIKit
import SwiftUI

/// What a status menu item asks of the window.
enum StatusMenuCommand: Equatable {
    case pause(WindowStatusMenu.PauseChoice)
    case action(WindowStatus.Action)
    case forget(ForgetRecentChoice)
    case privacy
    case preferences
}

/// The status menu, from the hi mark and the footer (SPEC 2.6.2): a native
/// menu, built from `WindowStatusMenu`, the same items the pictures draw.
@MainActor
enum StatusMenu {
    /// Opens the menu under `anchor` (the hi mark), or above it when it sits
    /// at the bottom of the sidebar (the footer).
    static func open(_ status: WindowStatus, from anchor: NSView, above: Bool,
                     perform: @escaping @MainActor (StatusMenuCommand) -> Void) {
        let menu = make(status, perform: perform)
        let height = menu.size.height
        let point = above
            ? NSPoint(x: 0, y: anchor.isFlipped ? -height - 4 : anchor.bounds.height + height + 4)
            : NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.height + 4 : -4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    static func make(_ status: WindowStatus, perform: @escaping @MainActor (StatusMenuCommand) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in WindowStatusMenu.items(status) {
            switch item {
            case let .title(title, _):
                let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                line.attributedTitle = NSAttributedString(
                    string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
                line.isEnabled = false
                menu.addItem(line)
            case let .line(text):
                let line = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            case .separator:
                menu.addItem(.separator())
            case .pause:
                let pause = NSMenuItem(title: NavigationCopy.pause, action: nil, keyEquivalent: "")
                let choices = NSMenu()
                for choice in WindowStatusMenu.PauseChoice.allCases {
                    choices.addItem(ClosureMenuItem(choice.title) { perform(.pause(choice)) })
                }
                pause.submenu = choices
                menu.addItem(pause)
            case let .action(action):
                menu.addItem(ClosureMenuItem(action.title) { perform(.action(action)) })
            case let .forget(choice):
                menu.addItem(ClosureMenuItem(WindowStatusMenu.title(choice)) { perform(.forget(choice)) })
            case .privacy:
                menu.addItem(ClosureMenuItem(NavigationCopy.privacyMenu) { perform(.privacy) })
            case .preferences:
                let item = ClosureMenuItem(NavigationCopy.preferencesMenu) { perform(.preferences) }
                item.keyEquivalent = ","
                item.keyEquivalentModifierMask = .command
                menu.addItem(item)
            }
        }
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func fire() {
        run()
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

/// The status menu as the system draws it, for off-screen pictures: a
/// picture can't open a real menu. The same items as the live one, from
/// `WindowStatusMenu`.
struct StatusMenuFacsimile: View {
    let status: WindowStatus
    /// Draws Pause highlighted with its submenu open.
    var showsPauseChoices = false

    var body: some View {
        HStack(alignment: .top, spacing: -6) {
            menuBox(items: WindowStatusMenu.items(status).map(Line.init))
                .frame(width: 234)
            if showsPauseChoices {
                menuBox(items: WindowStatusMenu.PauseChoice.allCases.map { Line(text: $0.title) })
                    .frame(width: 168)
                    .padding(.top, pauseOffset)
            }
        }
    }

    private var pauseOffset: CGFloat {
        var offset: CGFloat = 6
        for item in WindowStatusMenu.items(status) {
            if case .pause = item { return offset - 6 }
            offset += Line(item).height
        }
        return offset
    }

    struct Line: Identifiable {
        let id = UUID()
        var text = ""
        var key = ""
        var kind: Kind = .item
        var dot: WindowStatus.Dot?

        enum Kind { case title, detail, separator, item, submenu }

        init(text: String, key: String = "", kind: Kind = .item) {
            self.text = text
            self.key = key
            self.kind = kind
        }

        init(_ item: WindowStatusMenu.Item) {
            switch item {
            case let .title(title, dot):
                text = title
                kind = .title
                self.dot = dot
            case let .line(line):
                text = line
                kind = .detail
            case .separator:
                kind = .separator
            case .pause:
                text = NavigationCopy.pause
                kind = .submenu
            case let .action(action):
                text = action.title
            case let .forget(choice):
                text = WindowStatusMenu.title(choice)
            case .privacy:
                text = NavigationCopy.privacyMenu
            case .preferences:
                text = NavigationCopy.preferencesMenu
                key = "\u{2318},"
            }
        }

        var height: CGFloat {
            switch kind {
            case .separator: 11
            case .title: 24
            case .detail: 20
            default: 24
            }
        }
    }

    private func menuBox(items: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { line in
                lineView(line)
            }
        }
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MCI.Color.menu)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
    }

    @ViewBuilder
    private func lineView(_ line: Line) -> some View {
        switch line.kind {
        case .separator:
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        case .title:
            HStack(spacing: 7) {
                if let dot = line.dot { StatusDot(dot: dot) }
                Text(verbatim: line.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MCI.Color.foreground)
            }
            .padding(.leading, 14)
            .frame(height: line.height, alignment: .leading)
        case .detail:
            Text(verbatim: line.text)
                .font(.system(size: 12))
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .padding(.leading, 28)
                .padding(.trailing, 12)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: line.height, alignment: .leading)
        case .item, .submenu:
            let highlighted = line.kind == .submenu && showsPauseChoices
            HStack(spacing: 0) {
                Text(verbatim: line.text)
                    .font(.system(size: 13))
                    .foregroundStyle(highlighted ? Color.white : MCI.Color.foreground)
                Spacer(minLength: 12)
                if line.kind == .submenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(highlighted ? Color.white : MCI.Color.foregroundSecondary)
                }
                if !line.key.isEmpty {
                    Text(verbatim: line.key)
                        .font(.system(size: 12))
                        .foregroundStyle(MCI.Color.foregroundMuted)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: line.height)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(highlighted ? MCI.Color.accentFill : Color.clear)
                    .padding(.horizontal, 5)
            )
        }
    }
}
