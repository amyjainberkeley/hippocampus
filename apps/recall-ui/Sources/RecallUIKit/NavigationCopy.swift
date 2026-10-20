import Foundation

/// The words on the window's frame: the sidebar's rows and its sections
/// (SPEC 2.2 and 9, with SPEC-DELTA 1). Rows and sections are Title Case.
/// Every string passes `CopyStyleValidator` and `scripts/check-launch-copy.sh`.
public enum NavigationCopy {
    public static let today = "Today"
    public static let workingOn = "Working On"
    public static let showAll = "Show All"
    public static let library = "Library"
    public static let history = "History"
    public static let webPages = "Web Pages"
    public static let documents = "Documents"
    public static let code = "Code"
    public static let conversations = "Conversations"
    public static let lookedUp = "Looked Up"
    public static let aboutYou = "About You"
    public static let aiTools = "AI Tools"
    public static let privacy = "Privacy"
}
