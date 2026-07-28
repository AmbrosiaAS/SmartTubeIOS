import Foundation
import Testing
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore
#if canImport(UIKit)
import MediaPlayer

/// Tests that setupRemoteCommandCenter registers next/previous track commands and
/// that updateNowPlayingInfo correctly reflects hasNext/hasPrevious in the enabled
/// state of those commands.
///
/// Regression test for Task #233: lock screen Now Playing widget was missing
/// next/previous buttons because nextTrackCommand / previousTrackCommand were never
/// registered in setupRemoteCommandCenter().
@MainActor
struct NowPlayingCommandsTests {

    // MARK: - Next/previous command registration

    /// After setupRemoteCommandCenter(), nextTrackCommand must be registered and
    /// isEnabled must start false (no queue yet).
    @Test func nextTrackCommandRegisteredAfterSetup() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()
        let cmd = MPRemoteCommandCenter.shared().nextTrackCommand
        // The command should exist (non-nil isEnabled is always accessible).
        // The key assertion: we successfully called addTarget without crashing —
        // verified by the fact we reached this line — and isEnabled is false
        // because hasNext defaults to false.
        #expect(cmd.isEnabled == false)
    }

    @Test func previousTrackCommandRegisteredAfterSetup() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()
        let cmd = MPRemoteCommandCenter.shared().previousTrackCommand
        #expect(cmd.isEnabled == false)
    }

    // MARK: - isEnabled reflects hasNext / hasPrevious

    /// When hasNext is true and updateNowPlayingInfo() is called,
    /// nextTrackCommand.isEnabled must be true.
    @Test func nextTrackCommandEnabledWhenHasNext() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        // Provide a minimal video so updateNowPlayingInfo() doesn't bail early.
        let video = Video(id: "testVideo", title: "Test", channelTitle: "Chan")
        vm.currentVideo = video
        vm.hasNext = true
        vm.hasPrevious = false

        vm.updateNowPlayingInfo()

        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled == true)
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled == false)
    }

    @Test func previousTrackCommandEnabledWhenHasPrevious() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        let video = Video(id: "testVideo2", title: "Test 2", channelTitle: "Chan")
        vm.currentVideo = video
        vm.hasNext = false
        vm.hasPrevious = true

        vm.updateNowPlayingInfo()

        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled == false)
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled == true)
    }

    // MARK: - Lock Screen Controls style (settings.remoteControlStyle)
    //
    // Settings → Player → Lock Screen Controls picks which command pair the system
    // media controls expose either side of play/pause. Every case below drives
    // applyRemoteControlStyle(), which is the single place that decides enablement.

    /// `.automatic` is the default and must keep BOTH pairs live — skip commands
    /// always enabled, next/previous following queue availability. This is exactly
    /// what shipped before the setting existed, so upgrading installs see no change.
    @Test func automaticStyleKeepsBothCommandPairsAvailable() {
        let vm = PlaybackViewModel()
        var settings = AppSettings()
        settings.remoteControlStyle = .automatic
        vm.updateSettings(settings)
        vm.setupRemoteCommandCenter()

        vm.hasNext = true
        vm.hasPrevious = false
        vm.applyRemoteControlStyle()

        let center = MPRemoteCommandCenter.shared()
        #expect(center.nextTrackCommand.isEnabled == true)
        #expect(center.previousTrackCommand.isEnabled == false)
        #expect(center.skipForwardCommand.isEnabled == true)
        #expect(center.skipBackwardCommand.isEnabled == true)
    }

    /// `.trackSkip` — always next/previous video, so the skip commands must be off
    /// even when a queue exists.
    @Test func trackSkipStyleDisablesSkipCommands() {
        let vm = PlaybackViewModel()
        var settings = AppSettings()
        settings.remoteControlStyle = .trackSkip
        vm.updateSettings(settings)
        vm.setupRemoteCommandCenter()

        vm.hasNext = true
        vm.hasPrevious = true
        vm.applyRemoteControlStyle()

        let center = MPRemoteCommandCenter.shared()
        #expect(center.nextTrackCommand.isEnabled == true)
        #expect(center.previousTrackCommand.isEnabled == true)
        #expect(center.skipForwardCommand.isEnabled == false)
        #expect(center.skipBackwardCommand.isEnabled == false)
    }

    /// `.seekInterval` — always skip buttons, so next/previous must be off even when
    /// a next video is queued, and the configured seconds must reach
    /// preferredIntervals (that value is the number drawn inside the glyph).
    @Test func seekIntervalStyleDisablesTrackCommandsAndPublishesInterval() {
        let vm = PlaybackViewModel()
        var settings = AppSettings()
        settings.remoteControlStyle = .seekInterval
        settings.seekBackSeconds = 15
        settings.seekForwardSeconds = 15
        vm.updateSettings(settings)
        vm.setupRemoteCommandCenter()

        vm.hasNext = true
        vm.hasPrevious = true
        vm.applyRemoteControlStyle()

        let center = MPRemoteCommandCenter.shared()
        #expect(center.nextTrackCommand.isEnabled == false)
        #expect(center.previousTrackCommand.isEnabled == false)
        #expect(center.skipForwardCommand.isEnabled == true)
        #expect(center.skipBackwardCommand.isEnabled == true)
        #expect(center.skipForwardCommand.preferredIntervals.first?.intValue == 15)
        #expect(center.skipBackwardCommand.preferredIntervals.first?.intValue == 15)
    }

    /// Changing the setting while a player is already alive must re-apply without a
    /// reload — updateSettings(_:) calls applyRemoteControlStyle() for this reason.
    @Test func changingStyleAppliesToAlreadyRegisteredCommands() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()          // .automatic by default
        vm.hasNext = true
        vm.applyRemoteControlStyle()
        #expect(MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled == true)

        var settings = AppSettings()
        settings.remoteControlStyle = .trackSkip
        vm.updateSettings(settings)

        #expect(MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled == false)
        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled == true)
    }

    /// updateNowPlayingInfo() runs on every metadata refresh, so it must honour the
    /// style too rather than unconditionally re-enabling next/previous.
    @Test func updateNowPlayingInfoRespectsSeekIntervalStyle() {
        let vm = PlaybackViewModel()
        var settings = AppSettings()
        settings.remoteControlStyle = .seekInterval
        vm.updateSettings(settings)
        vm.setupRemoteCommandCenter()

        vm.currentVideo = Video(id: "styleVideo", title: "Style", channelTitle: "Chan")
        vm.hasNext = true
        vm.hasPrevious = true
        vm.updateNowPlayingInfo()

        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled == false)
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled == false)
    }

    // MARK: - Artwork fetch starts on new video

    /// updateNowPlayingInfo() should set cachedArtworkVideoID when a video with a
    /// thumbnailURL is first seen, signalling a fetch was kicked off.
    @Test func artworkFetchStartedForNewVideo() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        let thumbURL = URL(string: "https://i.ytimg.com/vi/testArtwork/hqdefault.jpg")!
        let video = Video(id: "artworkVideo", title: "Art", channelTitle: "Chan", thumbnailURL: thumbURL)
        vm.currentVideo = video
        vm.updateNowPlayingInfo()

        // cachedArtworkVideoID should be set after the first updateNowPlayingInfo call.
        #expect(vm.cachedArtworkVideoID == "artworkVideo")
    }

    /// Calling updateNowPlayingInfo() again for the same video must NOT reset
    /// cachedArtworkVideoID (i.e. the redundant-fetch guard works).
    @Test func artworkFetchNotRestartedForSameVideo() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        let thumbURL = URL(string: "https://i.ytimg.com/vi/sameVideo/hqdefault.jpg")!
        let video = Video(id: "sameVideo", title: "Same", channelTitle: "Chan", thumbnailURL: thumbURL)
        vm.currentVideo = video

        vm.updateNowPlayingInfo()
        // Simulate the fetch completing and setting cachedArtwork.
        vm.cachedArtwork = UIImage()

        vm.updateNowPlayingInfo()
        // cachedArtwork must still be non-nil (was not reset to nil on the second call).
        #expect(vm.cachedArtwork != nil)
        #expect(vm.cachedArtworkVideoID == "sameVideo")
    }
}
#endif
