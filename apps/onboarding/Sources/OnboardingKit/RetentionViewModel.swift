import Foundation

@MainActor
public final class RetentionViewModel: ObservableObject {
    @Published public var selectedPolicy: RetentionPolicy = .forever
    @Published public var customDays: Int = 14
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isSaving: Bool = false
    @Published public private(set) var saveError: String?

    private let store: RetentionStore

    public init(store: RetentionStore) {
        self.store = store
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        selectedPolicy = await store.currentPolicy()
        customDays = await store.currentCustomDays() ?? 14
    }

    @discardableResult
    public func save() async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let days = selectedPolicy == .custom ? customDays : nil
        do {
            try await store.setPolicy(selectedPolicy, customDays: days)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func saveThen(_ onSuccess: @MainActor () -> Void) async -> Bool {
        guard await save() else { return false }
        onSuccess()
        return true
    }
}
