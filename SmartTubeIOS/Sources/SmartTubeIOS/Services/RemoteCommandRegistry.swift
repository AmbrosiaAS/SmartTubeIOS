import Foundation
#if canImport(UIKit)
import MediaPlayer

/// Single owner for the app's MPRemoteCommandCenter handlers.
///
/// Why this exists: every player view model used to call
/// `command.removeTarget(nil)` in its `stop()`, `suspend()` and `deinit`.
/// `removeTarget(nil)` is global — it strips *every* handler on the shared
/// command center, not just the caller's. So a second `PlaybackViewModel`
/// (the Shorts player creates its own) being torn down while the main player
/// was mid-video silently wiped the main player's handlers: audio kept
/// playing, and the CarPlay steering-wheel / lock-screen buttons did nothing
/// until the next `load()` re-registered them. That failure leaves no
/// breadcrumb, because there is no handler left to log one.
///
/// The registry keeps the exclusivity the old code relied on (installing a
/// new owner replaces the previous one, so the TOS web player and the
/// AVPlayer pipeline never both answer a command) while making removal
/// owner-scoped: a stale instance asking to remove handlers it no longer owns
/// is ignored and breadcrumbed, instead of breaking the active player.
@MainActor
final class RemoteCommandRegistry {

    static let shared = RemoteCommandRegistry()

    /// Identifies one registering instance. A fresh UUID per instance, not
    /// `ObjectIdentifier`, because an address can be reused by the next
    /// allocation and `deinit` releases asynchronously.
    struct Owner: Sendable, Equatable {
        let id: UUID
        let label: String

        init(label: String) {
            self.id = UUID()
            self.label = label
        }

        var shortDescription: String { "\(label)#\(id.uuidString.prefix(4))" }
    }

    /// Collects handlers during `install` and keeps the tokens `addTarget`
    /// returns, so they can be removed individually later.
    final class Installer {
        fileprivate var tokens: [(MPRemoteCommand, Any)] = []

        func add(_ command: MPRemoteCommand,
                 _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            let token = command.addTarget(handler: handler)
            tokens.append((command, token))
        }
    }

    private(set) var owner: Owner?
    private var tokens: [(MPRemoteCommand, Any)] = []

    /// Number of handlers currently installed (test/diagnostic hook).
    var installedCommandCount: Int { tokens.count }

    /// Replaces whatever is installed with `owner`'s handlers.
    func install(owner: Owner, _ configure: (Installer) -> Void) {
        let previous = self.owner
        removeAllTokens()
        let installer = Installer()
        configure(installer)
        tokens = installer.tokens
        self.owner = owner
        RemoteCommandDiagnostics.log(
            "commands installed owner=\(owner.shortDescription) count=\(tokens.count) replaced=\(previous?.shortDescription ?? "none")")
    }

    /// Removes `owner`'s handlers. A no-op (breadcrumbed) if someone else has
    /// since installed theirs — that is the whole point.
    @discardableResult
    func remove(owner: Owner, reason: String) -> Bool {
        guard let current = self.owner else {
            RemoteCommandDiagnostics.log("commands remove no-op owner=\(owner.shortDescription) reason=\(reason) (nothing installed)")
            return false
        }
        guard current.id == owner.id else {
            RemoteCommandDiagnostics.log(
                "commands remove IGNORED owner=\(owner.shortDescription) reason=\(reason) — current owner is \(current.shortDescription)")
            return false
        }
        removeAllTokens()
        self.owner = nil
        RemoteCommandDiagnostics.log("commands removed owner=\(owner.shortDescription) reason=\(reason)")
        return true
    }

    /// For `deinit`, which is nonisolated: hops to the main actor and removes
    /// only if the dying instance is still the owner.
    nonisolated static func releaseFromDeinit(owner: Owner) {
        Task { @MainActor in
            RemoteCommandRegistry.shared.remove(owner: owner, reason: "deinit")
        }
    }

    private func removeAllTokens() {
        for (command, token) in tokens {
            command.removeTarget(token)
        }
        tokens.removeAll()
    }

    /// Test hook: drop everything so tests don't bleed into one another.
    func resetForTesting() {
        removeAllTokens()
        owner = nil
    }
}
#endif
