#if os(iOS)
import Foundation
import os
import SmartTubeIOSCore

// MARK: - CarPlayBridge

/// Hands the CarPlay scene the app's live service objects.
///
/// The CarPlay scene delegate is instantiated by UIKit straight from Info.plist,
/// outside the SwiftUI environment, so it cannot receive the AppEntry-owned
/// objects through dependency injection. AppEntry registers them here during
/// init — which runs at process launch even when the app is started directly
/// from the head unit with the phone locked.
@MainActor
public final class CarPlayBridge {

    public static let shared = CarPlayBridge()

    /// Every exit path in `play(video:)` used to be silent, so a head-unit pick
    /// that never started playback left no trace at all in the log — the CarPlay
    /// screen just sat there. Log each step.
    private let log = Logger(subsystem: "com.void.smarttube.app", category: "CarPlay")

    private(set) var api: InnerTubeAPI?
    private(set) var authService: AuthService?
    private var playerState: PlayerStateStore?
    private var tosState: TOSPlayerStateStore?

    /// True while a CarPlay head unit is connected (between the scene delegate's
    /// didConnect and didDisconnect callbacks). Read by the playback pipeline to
    /// select the background-safe muxed-first path: with the phone app closed or
    /// backgrounded, iOS throttles WKWebView JavaScript, so the HLS/PoToken
    /// WebView extraction stalls (two 40 s timeouts ≈ the ~85 s CarPlay-cold
    /// startup). When connected, playback skips WebView entirely and plays the
    /// Android progressive muxed stream — reliable, seekable, decent AAC audio.
    private(set) var isConnected = false

    private init() {}

    // MARK: - Scene lifecycle

    /// Called by CarPlaySceneDelegate when the head unit connects.
    func carPlaySceneDidConnect() {
        isConnected = true
        let state = "connected"
        log.notice("[bridge] CarPlay scene \(state, privacy: .public) — muxed-first playback enabled")
    }

    /// Called by CarPlaySceneDelegate when the head unit disconnects.
    func carPlaySceneDidDisconnect() {
        isConnected = false
        let state = "disconnected"
        log.notice("[bridge] CarPlay scene \(state, privacy: .public) — standard playback restored")
    }

    /// Registers the app's shared services. Safe to call repeatedly: only the
    /// first call wins, so a re-created `App` struct whose @State initial
    /// values were discarded by SwiftUI cannot swap in dead instances.
    public func configure(
        api: InnerTubeAPI,
        authService: AuthService,
        playerState: PlayerStateStore,
        tosState: TOSPlayerStateStore
    ) {
        guard self.api == nil else { return }
        self.api = api
        self.authService = authService
        self.playerState = playerState
        self.tosState = tosState
    }

    // MARK: - Playback state

    /// The video currently loaded in the AVPlayer pipeline, if any.
    var currentVideoId: String? { playerState?.vm.currentVideoId }

    /// True when the AVPlayer pipeline is actively playing.
    var isPlaying: Bool { playerState?.vm.isPlaying ?? false }

    /// True when a video is loaded (playing or paused) — i.e. the system
    /// Now Playing screen has real content to show.
    var hasActiveVideo: Bool { playerState?.currentVideo != nil }

    /// Index of the current video within the Current Queue, or nil when the
    /// active video didn't come from the queue. The queue may contain the same
    /// video ID twice, so position comes from the playlistIndex stamped by
    /// CurrentQueueStore.videoAt(index:) rather than an ID search.
    var currentQueueIndex: Int? {
        guard let video = playerState?.currentVideo,
              video.playlistId == CurrentQueueStore.playlistID else { return nil }
        return video.playlistIndex
    }

    // MARK: - Playback

    /// Appends `video` to the Current Queue and starts playing it.
    ///
    /// Picking from History or Watch Later adds that one video rather than
    /// replacing the queue with the whole list: the queue accumulates the
    /// driver's picks, and because the video is played tagged with the queue's
    /// playlistId, playback auto-advances through whatever else is queued
    /// behind it (see PlaybackViewModel.handlePlaybackEnd).
    ///
    /// CarPlay always uses the AVPlayer pipeline rather than PlayerRouter's
    /// default TOS web player: only AVPlayer drives MPNowPlayingInfoCenter and
    /// keeps playing with the phone locked, both of which CarPlay requires.
    /// The two pipelines are mutually exclusive (see PlayerRouter), so any
    /// active TOS playback is stopped first.
    func play(video: Video) {
        log.notice("[bridge] play requested id=\(video.id, privacy: .public) playerState=\(self.playerState == nil ? "nil" : "set", privacy: .public)")
        guard let playerState else {
            log.error("[bridge] play ABORTED — playerState is nil (configure() never ran)")
            return
        }
        if let tosState, tosState.presentation != .hidden {
            tosState.stop()
        }
        Task { @MainActor in
            // append() is a no-op when the video is already queued, so re-picking
            // a row plays it from its existing position instead of duplicating it.
            await CurrentQueueStore.shared.append(video)
            // videoAt(index:) stamps the queue playlistId/playlistIndex, which is
            // what auto-advance keys on — so play the stamped copy, not the raw row.
            var queued: Video?
            if let index = await CurrentQueueStore.shared.videos.firstIndex(where: { $0.id == video.id }) {
                queued = await CurrentQueueStore.shared.videoAt(index: index)
            }
            log.notice("[bridge] queue resolved id=\(video.id, privacy: .public) stamped=\(queued != nil, privacy: .public) — calling playerState.play")
            playerState.play(video: queued ?? video)
        }
    }

    /// Jumps playback to an existing queue entry without rebuilding the queue,
    /// so the rest of the up-next order is preserved.
    func playQueueItem(at index: Int) {
        guard let playerState else { return }
        if let tosState, tosState.presentation != .hidden {
            tosState.stop()
        }
        Task { @MainActor in
            guard let queued = await CurrentQueueStore.shared.videoAt(index: index) else { return }
            playerState.play(video: queued)
        }
    }

    // MARK: - Auth

    /// Ensures the API has fresh credentials before a CarPlay fetch.
    ///
    /// On a cold start from the head unit the SwiftUI scene never attaches, so
    /// AppEntry's onChange handlers that normally propagate the token never run,
    /// and the keychain session may still be mid-refresh. Kick the refresh and
    /// wait briefly for it — same 5 s pattern AppEntry uses for deep links.
    func refreshAuthIfNeeded() async {
        guard let authService, let api else { return }
        if authService.isSignedIn && authService.accessToken == nil {
            authService.handleForeground()
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)   // 100 ms
                if authService.accessToken != nil { break }
            }
        }
        await api.setAuthToken(authService.accessToken)
        await api.setSAPISID(authService.sapisid)
    }
}
#endif
