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

    // MARK: - Playback

    /// Starts `videos[startIndex]` on the native AVPlayer pipeline and seeds
    /// the Current Queue with the whole list so playback auto-advances to the
    /// next video when one ends — no glances at the screen needed while driving.
    ///
    /// CarPlay always uses the AVPlayer pipeline rather than PlayerRouter's
    /// default TOS web player: only AVPlayer drives MPNowPlayingInfoCenter and
    /// keeps playing with the phone locked, both of which CarPlay requires.
    /// The two pipelines are mutually exclusive (see PlayerRouter), so any
    /// active TOS playback is stopped first.
    func play(videos: [Video], startIndex: Int) {
        guard let playerState, videos.indices.contains(startIndex) else { return }
        if let tosState, tosState.presentation != .hidden {
            tosState.stop()
        }
        Task { @MainActor in
            await CurrentQueueStore.shared.replaceAll(with: videos)
            // videoAt(index:) tags the video with the queue playlistId, which is
            // what PlaybackViewModel.handlePlaybackEnd keys auto-advance on.
            let queued = await CurrentQueueStore.shared.videoAt(index: startIndex) ?? videos[startIndex]
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
