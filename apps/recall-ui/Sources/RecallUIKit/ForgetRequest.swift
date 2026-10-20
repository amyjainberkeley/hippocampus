import SwiftUI

/// What a person asked to forget from a page (SPEC 3.11), by ids and times
/// only, never content.
///
/// Pages only ask. The window's forget coordinator answers: it hides the rows
/// at once, asks first when the request is larger than one selection, shows
/// "Forgot 1 moment." with Undo, and deletes through the hold when the note
/// closes. Today, History and Library ask through `EnvironmentValues.forget`;
/// with no coordinator in the environment they offer no Forget at all, so
/// there is never a button that does nothing.
public enum ForgetRequest: Equatable, Hashable, Sendable {
    /// Moments picked in a list, newest first: a row of one window holds
    /// its whole run. Up to 20 are forgotten without a question.
    case moments([UInt64])
    /// Everything saved in a time, in every app: a session on Today
    /// ("2:12 to 2:36 PM"), an hour of History ("2 PM to 3 PM"). It is
    /// asked about first, with how many moments it holds.
    case range(ClosedRange<Int64>, label: String)

    /// How many moments a list's request names.
    public var momentCount: Int {
        switch self {
        case let .moments(ids): ids.count
        case .range: 0
        }
    }
}

/// The window's answer to a `ForgetRequest`.
public struct ForgetAction: Sendable {
    private let perform: @MainActor @Sendable (ForgetRequest) -> Void

    public init(_ perform: @escaping @MainActor @Sendable (ForgetRequest) -> Void) {
        self.perform = perform
    }

    @MainActor
    public func callAsFunction(_ request: ForgetRequest) {
        perform(request)
    }
}

private struct ForgetActionKey: EnvironmentKey {
    static let defaultValue: ForgetAction? = nil
}

private struct ForgottenMomentsKey: EnvironmentKey {
    static let defaultValue: Set<UInt64> = []
}

public extension EnvironmentValues {
    /// How a page asks to forget: the shell's forget coordinator. Nil shows
    /// no Forget anywhere.
    var forget: ForgetAction? {
        get { self[ForgetActionKey.self] }
        set { self[ForgetActionKey.self] = newValue }
    }

    /// Moments forgotten but not yet deleted (their Undo note is still up):
    /// lists leave them out at once, and bring them back on Undo.
    var forgottenMoments: Set<UInt64> {
        get { self[ForgottenMomentsKey.self] }
        set { self[ForgottenMomentsKey.self] = newValue }
    }
}
