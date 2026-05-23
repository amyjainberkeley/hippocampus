import Foundation

public struct LivePreviewEvent: Sendable, Identifiable {
    public let id: Int
    public let time: String
    public let appName: String
    public let detail: String
    public let systemIcon: String
    public let isBlocked: Bool

    public init(id: Int, time: String, appName: String, detail: String,
                systemIcon: String, isBlocked: Bool) {
        self.id = id
        self.time = time
        self.appName = appName
        self.detail = detail
        self.systemIcon = systemIcon
        self.isBlocked = isBlocked
    }
}

public enum LivePreviewEvents {
    public static let demo: [LivePreviewEvent] = [
        LivePreviewEvent(
            id: 0, time: "12:00:01", appName: "VS Code",
            detail: "editing OnboardingApp.swift",
            systemIcon: "chevron.left.forwardslash.chevron.right", isBlocked: false
        ),
        LivePreviewEvent(
            id: 1, time: "12:00:04", appName: "Safari",
            detail: "developer.apple.com/documentation",
            systemIcon: "safari", isBlocked: false
        ),
        LivePreviewEvent(
            id: 2, time: "12:00:07", appName: "Slack",
            detail: "#engineering",
            systemIcon: "bubble.left.and.bubble.right", isBlocked: false
        ),
        LivePreviewEvent(
            id: 3, time: "12:00:10", appName: "1Password",
            detail: "sensitive app detected",
            systemIcon: "lock.shield", isBlocked: true
        ),
        LivePreviewEvent(
            id: 4, time: "12:00:13", appName: "Figma",
            detail: "MCI Onboarding Design",
            systemIcon: "paintbrush", isBlocked: false
        ),
    ]
}
