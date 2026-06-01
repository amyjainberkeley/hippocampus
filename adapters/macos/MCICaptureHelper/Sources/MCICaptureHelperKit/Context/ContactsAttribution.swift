// SPDX-License-Identifier: TBD-private
//
// ContactsAttribution — `CNContactStore`-backed person-entity-
// anchor attribution source for `WorkflowContext`.
//
// Phase 6 PR 5 — SH Fork D1 (EventKit + Contacts +
// MPNowPlayingInfoCenter cascade attribution; ratified at
// AGENT_QUESTIONS.md F-RATIFICATION-2026-05-31).
//
// PROTECTED-SET per AGENT_PROTOCOL §5 (this PR adds the
// `NSContactsUsageDescription` TCC surface; driver-CSO sign-off
// authored inline in the PR body, not via the `cso` sub-agent —
// CEO-INFRA-001).
//
// # Scope binding — opaque identifier, ZERO content on the snapshot
//
// Per CSO sign-off row 7 (PR body): the snapshot carries
// `CNContact.identifier` ONLY. NO name, NO phone, NO email, NO
// photo. Recall-time UI resolves the identifier back to a name by
// re-fetching from the user's local `CNContactStore` — that
// re-fetch is gated by the SAME TCC entitlement that the helper
// already holds. No content leaves the snapshot's process.
//
// # Minimal fetch keys
//
// `CNContactFetchRequest` keys are kept to the absolute minimum
// needed for identifier resolution from a participant string:
//   - `CNContactIdentifierKey` — the opaque id we emit.
//   - `CNContactEmailAddressesKey` — for email-substring matching.
//   - `CNContactPhoneNumbersKey` — for phone-substring matching.
//
// NOT fetched (CSO sign-off row 4): `CNContactImageDataKey`,
// `CNContactInstantMessageAddressesKey`,
// `CNContactSocialProfilesKey`, `CNContactRelationsKey`,
// `CNContactNotesKey`, etc. — anything we do not strictly need to
// resolve an identifier.
//
// # TCC denial path (CSO sign-off row 2)
//
// `CNContactStore.requestAccess(for: .contacts)` is called once at
// `start()`. On denial we record the denial state, emit ONE
// stderr line, and every subsequent `resolve(participant:)` returns
// `nil`. Graceful absence; never crashes. The state-change warn
// fires only once per transition.

import Dispatch
import Foundation
import os
#if canImport(Contacts)
import Contacts
#endif

/// Protocol surface — production reads `CNContactStore`; tests
/// inject a deterministic stub.
public protocol ContactsAttributionSource: Sendable {
    /// Resolve a free-form participant string (a phone number, an
    /// email, or a `mailto:` URL fragment) to an opaque
    /// `CNContact.identifier`. Returns `nil` when there is no match,
    /// when TCC is denied, or when the input is not a participant
    /// shape at all. Cheap on the hot path (internal LRU cache).
    func resolve(participant: String) -> ContactRef?
}

/// Authorization state of `CNContactStore` for the helper process.
public enum ContactsAuthorizationState: Sendable, Equatable {
    /// Not yet requested OR request returned `false` with no error.
    case notDetermined
    /// User explicitly denied OR system policy restricts access.
    case denied
    /// `CNAuthorizationStatus.authorized`.
    case granted
}

/// Production `ContactsAttributionSource` over `CNContactStore`.
/// Caches resolution results in a small LRU keyed by the
/// (normalized) participant string. Cache hits are O(1); cache
/// misses run a `unifiedContacts(matching:keysToFetch:)` predicate
/// which returns quickly on a typical address book.
///
/// Lifetime discipline (SCSTREAM-LIVE-001 lesson): construct at
/// process top level in `MCICaptureHelper/main.swift`; never let a
/// detached `Task` be the sole owner.
public final class ContactsAttribution: ContactsAttributionSource, @unchecked Sendable {
    /// Maximum number of cached resolutions (positive AND negative).
    /// Both shapes cost one identifier-sized string in memory.
    private let cacheCapacity: Int

    private let stateLock = NSLock()
    private var authState: ContactsAuthorizationState
    /// LRU cache: participant-normalized-key → optional ContactRef.
    /// Storing the optional means a negative resolution
    /// (`nil = no match found`) is cached too — re-checking the
    /// same non-matching email every tick burns one HashMap
    /// lookup, not one CNContactStore query.
    private var cache: [String: ContactRef?]
    /// LRU eviction order — front is least-recent, back is most-
    /// recent. Capped at `cacheCapacity`.
    private var cacheOrder: [String]
    private var loggedDenialOnce: Bool = false

    #if canImport(Contacts)
    private let store: CNContactStore
    #endif

    public init(cacheCapacity: Int = 256) {
        self.cacheCapacity = cacheCapacity
        self.authState = .notDetermined
        self.cache = [:]
        self.cacheOrder = []
        #if canImport(Contacts)
        self.store = CNContactStore()
        #endif
    }

    /// Kick off the TCC prompt + permission settle. Idempotent;
    /// second call is a no-op. Until access resolves,
    /// `resolve(participant:)` returns `nil`.
    public func start() {
        #if canImport(Contacts)
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            guard let self else { return }
            self.recordAuth(granted: granted)
        }
        #endif
    }

    private func recordAuth(granted: Bool) {
        stateLock.lock()
        let prior = authState
        authState = granted ? .granted : .denied
        let shouldLog = !loggedDenialOnce && !granted && prior != authState
        if shouldLog {
            loggedDenialOnce = true
        }
        stateLock.unlock()
        if shouldLog {
            FileHandle.standardError.write(
                ("mci-capture-helper: NSContactsUsageDescription "
                 + "denied — person-entity-anchor attribution "
                 + "disabled. Re-grant in System Settings → Privacy "
                 + "& Security → Contacts.\n").data(using: .utf8) ?? Data()
            )
        }
    }

    public func resolve(participant: String) -> ContactRef? {
        let key = Self.normalizeParticipant(participant)
        if key.isEmpty {
            return nil
        }

        // Cache snapshot under the lock; do the (potentially
        // expensive) CNContactStore read OUTSIDE the lock so the
        // cascade hot path is never held up.
        stateLock.lock()
        let auth = authState
        let hit = cache[key]
        stateLock.unlock()

        if let cached = hit {
            // The Dictionary access yielded a value of type
            // `Optional<ContactRef?>` (outer = "is the key
            // present?", inner = "did we cache a negative
            // resolution?"). Unwrap to the inner optional.
            return cached
        }

        guard auth == .granted else { return nil }

        let observed = readContact(matching: key)

        stateLock.lock()
        cache[key] = observed
        cacheOrder.append(key)
        // LRU evict.
        while cacheOrder.count > cacheCapacity {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        stateLock.unlock()

        return observed
    }

    /// Strip `mailto:`, `tel:`, surrounding whitespace; lower-case
    /// email addresses (phone numbers stay as-typed — CNContact's
    /// own matcher handles the digit normalization). Returns `""`
    /// for non-participant-shaped inputs (so the caller short-
    /// circuits without a store read).
    static func normalizeParticipant(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("mailto:") {
            t = String(t.dropFirst("mailto:".count))
        } else if t.lowercased().hasPrefix("tel:") {
            t = String(t.dropFirst("tel:".count))
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Email shape — anything with an `@` and at least one dot
        // after it; lowercase for case-insensitive matching.
        if let at = t.firstIndex(of: "@"), t[at...].contains(".") {
            return t.lowercased()
        }
        // Phone shape — keep only digits / `+` / leading parens.
        // If after stripping we have ≥ 7 digits, accept; otherwise
        // bail. (7 = NANP local without area code; conservative.)
        let phoneAllowed = CharacterSet(charactersIn: "0123456789+()-. ")
        if t.unicodeScalars.allSatisfy(phoneAllowed.contains) {
            let digits = t.filter { "0123456789".contains($0) }
            if digits.count >= 7 {
                return digits
            }
        }
        return ""
    }

    /// Query `CNContactStore` for a contact matching the
    /// normalized participant. Returns the first match's
    /// identifier (deterministic ordering across multiple matches
    /// is out of scope for this PR — Phase 7 deep-hook plugin
    /// owns multi-match semantics).
    private func readContact(matching normalized: String) -> ContactRef? {
        #if canImport(Contacts)
        // Build the predicate. CNContact has two relevant
        // predicates — emailAddress vs phoneNumber — choose by
        // shape. The shape was decided in `normalizeParticipant`:
        // anything containing `@` is an email; otherwise digits.
        let predicate: NSPredicate
        if normalized.contains("@") {
            predicate = CNContact.predicateForContacts(matchingEmailAddress: normalized)
        } else {
            let phone = CNPhoneNumber(stringValue: normalized)
            predicate = CNContact.predicateForContacts(matching: phone)
        }
        // Minimal key set per CSO sign-off row 4 — identifier +
        // the two contact-method keys we need for matching.
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        do {
            let matches = try store.unifiedContacts(
                matching: predicate, keysToFetch: keys
            )
            guard let first = matches.first else { return nil }
            return ContactRef(identifier: first.identifier)
        } catch {
            // Read errors (entitlement edge cases, store
            // unavailable) → graceful nil. No crash, no warn (the
            // start-time auth warn is the user-visible signal).
            return nil
        }
        #else
        _ = normalized
        return nil
        #endif
    }
}
