import Foundation
import Testing
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore
#if canImport(UIKit)
import MediaPlayer

/// Tests for the remote-command wiring in setupRemoteCommandCenter() /
/// updateNowPlayingInfo().
///
/// History: originally regression tests for Task #233 (next/previous track
/// commands were never registered). The expected behavior changed with the
/// CarPlay steering-wheel fix: next/previous-track are now remapped to ±15 s
/// seeks and stay ALWAYS enabled — they must no longer be gated on
/// hasNext/hasPrevious, which left them dead for the first video of a session.
@MainActor
struct NowPlayingCommandsTests {

    // MARK: - Next/previous command registration

    /// After setupRemoteCommandCenter(), nextTrackCommand must be registered and
    /// enabled even with no queue — it is a +15 s seek button, not queue navigation.
    @Test func nextTrackCommandAlwaysEnabledAfterSetup() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()
        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled == true)
    }

    @Test func previousTrackCommandAlwaysEnabledAfterSetup() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled == true)
    }

    /// updateNowPlayingInfo() must NOT gate next/previous on hasNext/hasPrevious —
    /// the old gating disabled the CarPlay steering-wheel buttons whenever the
    /// history stack was empty (i.e. the first video of every drive).
    @Test func trackCommandsStayEnabledRegardlessOfQueueState() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        // Provide a minimal video so updateNowPlayingInfo() doesn't bail early.
        let video = Video(id: "testVideo", title: "Test", channelTitle: "Chan")
        vm.currentVideo = video
        vm.hasNext = false
        vm.hasPrevious = false

        vm.updateNowPlayingInfo()

        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled == true)
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled == true)
    }

    // MARK: - Skip interval

    /// The CarPlay/lock-screen skip buttons must advertise the 15 s interval.
    @Test func skipCommandsAdvertiseFifteenSeconds() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()
        let center = MPRemoteCommandCenter.shared()
        #expect(center.skipForwardCommand.preferredIntervals == [15])
        #expect(center.skipBackwardCommand.preferredIntervals == [15])
    }

    // MARK: - Rapid relative seeks accumulate

    /// Successive seekRelative calls must chain off the in-flight seek target, not
    /// currentTime (which only updates in the seek's async completion). Without
    /// this, N rapid CarPlay presses moved far less than N × 15 s.
    @Test func rapidRelativeSeeksAccumulate() {
        let vm = PlaybackViewModel()
        vm.currentTime = 100

        vm.seekRelative(seconds: 15)
        vm.seekRelative(seconds: 15)
        vm.seekRelative(seconds: 15)

        #expect(vm.pendingSeekTarget == 145)
    }

    /// Accumulated forward seeks must clamp to the video duration.
    @Test func relativeSeekClampsToDuration() {
        let vm = PlaybackViewModel()
        vm.currentTime = 100
        vm.duration = 120

        vm.seekRelative(seconds: 15)
        vm.seekRelative(seconds: 15)

        #expect(vm.pendingSeekTarget == 120)
    }

    /// Accumulated backward seeks must clamp to zero.
    @Test func relativeSeekClampsToZero() {
        let vm = PlaybackViewModel()
        vm.currentTime = 20

        vm.seekRelative(seconds: -15)
        vm.seekRelative(seconds: -15)

        #expect(vm.pendingSeekTarget == 0)
    }

    // MARK: - Remote-command diagnostics caps

    /// Breadcrumbing must stop at the per-session cap so a long drive can't
    /// spam the Crashlytics breadcrumb buffer or Firebase quota.
    @Test func remoteDiagnosticsBreadcrumbsCapPerSession() {
        RemoteCommandDiagnostics.resetForTesting()
        for i in 0..<(RemoteCommandDiagnostics.breadcrumbCap + 50) {
            RemoteCommandDiagnostics.log("test breadcrumb \(i)")
        }
        #expect(RemoteCommandDiagnostics.breadcrumbCount == RemoteCommandDiagnostics.breadcrumbCap)
        // The 60 s flush timer is armed but has not fired within this test.
        #expect(RemoteCommandDiagnostics.reportCount == 0)
        RemoteCommandDiagnostics.resetForTesting()
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
