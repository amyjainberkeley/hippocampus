import Foundation

public struct CascadeStep: Sendable, Equatable, Identifiable {
    public var id: Int { section }
    public let section: Int
    public let label: String
    public let detail: String

    public init(section: Int, label: String, detail: String) {
        self.section = section
        self.label = label
        self.detail = detail
    }
}

// Static model for the "What MCI Sees" cascade order graphic.
// ADR-0013 cascade: §2 → §3 → §4 → §5 → §6 → §7.
public enum CascadeSteps {
    public static let ordered: [CascadeStep] = [
        CascadeStep(section: 1, label: "Source Denylist",
                    detail: "Apps on the denylist are blocked before capture starts."),
        CascadeStep(section: 2, label: "DRM Detection",
                    detail: "DRM-protected video (Apple TV, Netflix) is never captured."),
        CascadeStep(section: 3, label: "Secure Input",
                    detail: "macOS secure-input mode blocks capture while typing passwords."),
        CascadeStep(section: 4, label: "Accessibility Backstop",
                    detail: "Password fields and secure text areas are detected and blocked."),
        CascadeStep(section: 5, label: "Denylist Drift",
                    detail: "If an app moves to the denylist mid-session, capture stops."),
        CascadeStep(section: 6, label: "OCR Secret Scrub",
                    detail: "Text matching secret/PII patterns is redacted after OCR."),
        CascadeStep(section: 7, label: "Fail-Closed Catchall",
                    detail: "Unknown apps are refused by default. Safety is the default."),
    ]
}
