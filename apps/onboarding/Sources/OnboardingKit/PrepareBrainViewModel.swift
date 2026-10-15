import Foundation

@MainActor
public final class PrepareBrainViewModel: ObservableObject {
    public enum KeyState: Sendable, Equatable {
        case checking
        case generating
        case ready
        case failed(String)
    }

    @Published public private(set) var keyState: KeyState = .checking

    private let keyGenerator: any KeyGenerator

    /// Setup makes the encryption key and nothing else: it downloads no
    /// model. Answers come from Apple Intelligence or a model the person
    /// already runs (Ollama, LM Studio).
    public init(keyGenerator: any KeyGenerator) {
        self.keyGenerator = keyGenerator
    }

    public var canContinue: Bool { keyState == .ready }

    /// Key setup failed; running `generateKey()` again tries once more.
    public var keyFailed: Bool {
        if case .failed = keyState { return true }
        return false
    }

    /// Start key setup, or return at once when it is running or done. Setup
    /// starts when Permissions appears, so the key is usually ready by
    /// Promise; a ready key never goes back to "Setting up", or Back then
    /// Continue would turn Start Remembering off again.
    public func generateKey() async {
        guard keyState != .generating, keyState != .ready else { return }
        keyState = .generating
        do {
            let exists = await keyGenerator.keyExists()
            if !exists {
                try await keyGenerator.generateKey()
            }
            keyState = .ready
        } catch {
            keyState = .failed(error.localizedDescription)
        }
    }
}
