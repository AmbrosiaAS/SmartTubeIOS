import Foundation

// MARK: - VideoStateStore
//
// Persists per-video watch position and progress fraction across sessions.
// Mirrors Android's VideoStateService + VideoStateController.
//
// Thread-safe: implemented as a Swift actor.

public actor VideoStateStore: UserDefaultsBackedStore {

    // MARK: - State

    public struct State: Codable, Sendable {
        /// Saved playback position in seconds.
        public var position: TimeInterval
        /// Fraction watched: 0.0 – 1.0
        public var watchedFraction: Double
        /// When this entry was last updated (used for pruning old entries).
        public var timestamp: Date

        public init(position: TimeInterval, watchedFraction: Double) {
            self.position = position
            self.watchedFraction = watchedFraction
            self.timestamp = Date()
        }
    }

    // MARK: - Singleton

    public static let shared = VideoStateStore()

    // MARK: - Private

    static let defaultsKey = "st_video_states"
    private static let maxEntries = 1_000

    private var states: [String: State] = [:]
    let defaults: UserDefaults

    private init() {
        self.defaults = .standard
        if let loaded = Self.loadFrom(.standard) { states = loaded }
    }

    /// Designated initializer for unit testing. Pass a unique `suiteName` string
    /// (e.g. `"test-\(UUID().uuidString)"`) to get a fully isolated store with
    /// no shared `UserDefaults` state — `String` is `Sendable` so this crosses
    /// actor isolation boundaries cleanly in Swift 6 strict concurrency.
    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if let loaded = Self.loadFrom(self.defaults) { states = loaded }
    }

    // MARK: - Public API

    /// Returns the saved state for `videoId`, or nil if nothing was saved.
    public func state(for videoId: String) -> State? {
        states[videoId]
    }

    /// Position to resume `videoId` from, or nil to start from the beginning.
    ///
    /// The locally saved position wins. When there is none — the video was watched
    /// on another device, or before this install — falls back to YouTube's own
    /// `serverProgress` (`Video.watchProgress`, the fraction behind the red bar on
    /// history thumbnails), so a card that shows progress always resumes from it.
    public func resumePosition(for videoId: String, serverProgress: Double?, duration: TimeInterval) -> TimeInterval? {
        Self.resumePosition(local: states[videoId], serverProgress: serverProgress, duration: duration)
    }

    /// Pure form of `resumePosition(for:serverProgress:duration:)`. Applies the same
    /// bounds as `save` (> 5 s in, < 95 % watched) to the server-derived position.
    public static func resumePosition(local: State?, serverProgress: Double?, duration: TimeInterval) -> TimeInterval? {
        if let pos = local?.position, pos > 5 { return pos }
        guard let fraction = serverProgress, fraction > 0, fraction < 0.95, duration > 1 else { return nil }
        let pos = fraction * duration
        return pos > 5 ? pos : nil
    }

    /// Persists watch position. Automatically prunes entries near the start
    /// (< 5 s) or near the end (> 95 %) — mirrors Android's RESTORE_POSITION_PERCENTS.
    public func save(videoId: String, position: TimeInterval, duration: TimeInterval) {
        let fraction = duration > 1 ? min(position / duration, 1.0) : 0.0
        if position > 5, fraction < 0.95 {
            states[videoId] = State(position: position, watchedFraction: fraction)
            prune()
        } else {
            states.removeValue(forKey: videoId)
        }
        persist()
    }

    /// Removes any saved position for `videoId` (e.g. when the user finishes watching).
    public func clear(videoId: String) {
        states.removeValue(forKey: videoId)
        persist()
    }

    // MARK: - UserDefaultsBackedStore

    func encodedValue() -> [String: State] { states }
    func decodeValue(_ decoded: [String: State]) { states = decoded }

    func afterPersist() {
        let value = states
        Task { await iCloudSyncManager.shared.push(.videoState, value) }
    }

    // MARK: - Persistence

    private func prune() {
        guard states.count > Self.maxEntries else { return }
        let sorted = states.sorted { $0.value.timestamp < $1.value.timestamp }
        sorted.prefix(states.count - Self.maxEntries).forEach { states.removeValue(forKey: $0.key) }
    }
}
