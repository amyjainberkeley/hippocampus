import Foundation

@MainActor
public final class TrustPanelViewModel: ObservableObject {
    @Published public private(set) var allowlistEntries: [AllowlistEntry] = []
    @Published public private(set) var denylistEntries: [DenylistEntry] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var newDenyValue: String = ""
    @Published public var newDenyType: DenylistEntry.EntryType = .bundleId

    public let denylistCategories: [DenylistCategory] = DenylistCategories.v1
    public let cascadeSteps: [CascadeStep] = CascadeSteps.ordered

    private let allowlistStore: AllowlistStore
    private let denylistStore: DenylistEditorStore

    public init(allowlistStore: AllowlistStore, denylistStore: DenylistEditorStore) {
        self.allowlistStore = allowlistStore
        self.denylistStore = denylistStore
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        allowlistEntries = await allowlistStore.entries()
        await denylistStore.load()
        denylistEntries = await denylistStore.allEntries()
    }

    public func addDenyEntry() async {
        let value = newDenyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        await denylistStore.addUserEntry(type: newDenyType, value: value)
        denylistEntries = await denylistStore.allEntries()
        newDenyValue = ""
    }

    public func removeDenyEntry(id: String) async {
        let removed = await denylistStore.removeUserEntry(id: id)
        if removed {
            denylistEntries = await denylistStore.allEntries()
        }
    }
}
