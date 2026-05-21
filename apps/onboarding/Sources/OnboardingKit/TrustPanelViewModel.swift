import Foundation

@MainActor
public final class TrustPanelViewModel: ObservableObject {
    @Published public private(set) var allowlistEntries: [AllowlistEntry] = []
    @Published public private(set) var isLoading: Bool = false

    public let denylistCategories: [DenylistCategory] = DenylistCategories.v1
    public let cascadeSteps: [CascadeStep] = CascadeSteps.ordered

    private let store: AllowlistStore

    public init(store: AllowlistStore) {
        self.store = store
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        allowlistEntries = await store.entries()
    }
}
