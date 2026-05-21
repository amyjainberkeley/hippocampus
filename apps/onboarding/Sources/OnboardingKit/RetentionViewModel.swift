import Foundation

@MainActor
public final class RetentionViewModel: ObservableObject {
    @Published public var selectedPolicy: RetentionPolicy = .forever
    @Published public var customDays: Int = 14
    @Published public private(set) var isLoading: Bool = false

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

    public func save() async {
        let days = selectedPolicy == .custom ? customDays : nil
        await store.setPolicy(selectedPolicy, customDays: days)
    }
}
