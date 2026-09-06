import Foundation

/// The app has one audible output owner, shared by recordings and synthesized audio.
/// Transfer is synchronous so the old output is silent before the next one starts.
@MainActor
public final class PlaybackCoordinator {
    public static let shared = PlaybackCoordinator()
    public private(set) var activeToken: UUID?
    private var interrupt: (() -> Void)?

    public init() {}

    @discardableResult
    public func acquire(token: UUID, interrupt: @escaping () -> Void) -> Bool {
        if activeToken == token {
            self.interrupt = interrupt
            return true
        }
        let previous = self.interrupt
        // Publish the new token first: the previous owner's pause/release cannot
        // accidentally release it. A synchronous subscriber may transfer it again.
        activeToken = token
        self.interrupt = interrupt
        previous?()
        return activeToken == token
    }

    public func release(token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
        interrupt = nil
    }
}
