#if os(iOS)
import Foundation
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

    private(set) var api: InnerTubeAPI?
    private(set) var authService: AuthService?
    private var playerState: PlayerStateStore?
    private var tosState: TOSPlayerStateStore?

    private init() {}

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

    /// Starts playback of `video` on the native AVPlayer pipeline.
    ///
    /// CarPlay always uses the AVPlayer pipeline rather than PlayerRouter's
    /// default TOS web player: only AVPlayer drives MPNowPlayingInfoCenter and
    /// keeps playing with the phone locked, both of which CarPlay requires.
    /// The two pipelines are mutually exclusive (see PlayerRouter), so any
    /// active TOS playback is stopped first.
    func play(video: Video) {
        guard let playerState else { return }
        if let tosState, tosState.presentation != .hidden {
            tosState.stop()
        }
        playerState.play(video: video)
    }
}
#endif
