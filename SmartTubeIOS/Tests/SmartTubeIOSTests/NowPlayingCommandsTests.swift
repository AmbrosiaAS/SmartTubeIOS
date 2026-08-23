import Foundation
import Testing
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore
#if canImport(UIKit)
import MediaPlayer
import AVFoundation

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

    // MARK: - Now Playing playback-state publishing

    private func cachedElapsed(_ vm: PlaybackViewModel) -> Double? {
        (vm.nowPlayingInfoCache[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue
    }

    /// updateNowPlayingPlayback() must backfill MPMediaItemPropertyPlaybackDuration
    /// once duration resolves: at load time updateNowPlayingInfo() runs with
    /// duration == 0 and omits the key, and without it the system renders no
    /// progress bar at all — the bar used to stay missing until the next full
    /// metadata publish happened to fire.
    @Test func playbackUpdateBackfillsDurationOnceKnown() {
        let vm = PlaybackViewModel()
        vm.currentVideo = Video(id: "durVideo", title: "Dur", channelTitle: "Chan")
        vm.updateNowPlayingInfo() // duration == 0 → key omitted
        #expect(vm.nowPlayingInfoCache[MPMediaItemPropertyPlaybackDuration] == nil)

        vm.duration = 300
        vm.updateNowPlayingPlayback()
        #expect((vm.nowPlayingInfoCache[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue == 300)
    }

    /// While duration is unknown (0 — also the live-stream case, where the item
    /// duration is indefinite and video.duration is nil), updateNowPlayingPlayback()
    /// must NOT invent a finite duration.
    @Test func playbackUpdateDoesNotInventDurationWhenUnknown() {
        let vm = PlaybackViewModel()
        vm.currentVideo = Video(id: "liveVideo", title: "Live", channelTitle: "Chan")
        vm.updateNowPlayingInfo()

        vm.updateNowPlayingPlayback()
        #expect(vm.nowPlayingInfoCache[MPMediaItemPropertyPlaybackDuration] == nil)
    }

    /// The periodic elapsed-time refresh must publish on the first tick, then
    /// throttle to nowPlayingElapsedRefreshInterval — NOT write the info center
    /// on every 0.5 s time-observer tick.
    @Test func elapsedRefreshIsThrottled() {
        let vm = PlaybackViewModel()
        vm.currentVideo = Video(id: "throttleVideo", title: "Throttle", channelTitle: "Chan")
        vm.updateNowPlayingInfo()

        let t0 = Date()
        vm.currentTime = 10
        vm.refreshNowPlayingElapsedTimeIfNeeded(now: t0) // first tick → publishes
        #expect(cachedElapsed(vm) == 10)

        vm.currentTime = 11
        vm.refreshNowPlayingElapsedTimeIfNeeded(now: t0.addingTimeInterval(1)) // inside window → throttled
        #expect(cachedElapsed(vm) == 10)

        vm.currentTime = 13
        vm.refreshNowPlayingElapsedTimeIfNeeded(now: t0.addingTimeInterval(PlaybackViewModel.nowPlayingElapsedRefreshInterval))
        #expect(cachedElapsed(vm) == 13)
    }

    /// After clearNowPlayingInfo() (stop) a straggling time-observer tick must
    /// not resurrect a ghost Now Playing entry containing only elapsed/rate.
    @Test func elapsedRefreshSkipsWhenNothingPublished() {
        let vm = PlaybackViewModel()
        vm.clearNowPlayingInfo()
        vm.currentTime = 42
        vm.refreshNowPlayingElapsedTimeIfNeeded(now: .distantFuture)
        #expect(vm.nowPlayingInfoCache.isEmpty)
    }

    // MARK: - Remote-command ownership (RemoteCommandRegistry)

    /// The old code called removeTarget(nil) from every VM's stop/suspend/deinit,
    /// which stripped the *active* player's handlers whenever any other VM (e.g.
    /// the Shorts player) was torn down mid-video. Removal must be owner-scoped.
    @Test func staleOwnerCannotRemoveActiveHandlers() {
        let registry = RemoteCommandRegistry.shared
        registry.resetForTesting()

        let first = PlaybackViewModel()
        first.setupRemoteCommandCenter()
        let second = PlaybackViewModel()
        second.setupRemoteCommandCenter()

        #expect(registry.owner == second.remoteOwner)
        let installed = registry.installedCommandCount
        #expect(installed == 10)

        // A VM that no longer owns the handlers must not be able to remove them.
        first.releaseRemoteCommands(reason: "test-stale")
        #expect(registry.owner == second.remoteOwner)
        #expect(registry.installedCommandCount == installed)

        // The real owner can.
        second.releaseRemoteCommands(reason: "test-owner")
        #expect(registry.owner == nil)
        #expect(registry.installedCommandCount == 0)
        registry.resetForTesting()
    }

    /// Installing replaces the previous owner outright — the AVPlayer VM and the
    /// TOS web player must never both answer a button.
    @Test func installReplacesPreviousOwner() {
        let registry = RemoteCommandRegistry.shared
        registry.resetForTesting()
        let a = PlaybackViewModel()
        a.setupRemoteCommandCenter()
        let b = PlaybackViewModel()
        b.setupRemoteCommandCenter()
        #expect(registry.owner == b.remoteOwner)
        #expect(registry.installedCommandCount == 10)   // not 20
        registry.resetForTesting()
    }

    // MARK: - Audio interruption

    /// iOS can deliver `.began` twice in a row (seen on device, 8 ms apart). The
    /// second arrives with isPlaying already false; it must not overwrite the
    /// "was playing" flag, or the `.ended` auto-resume is skipped and the car
    /// stays silent until the driver presses play.
    @Test func doubleInterruptionBeganKeepsWasPlayingFlag() async throws {
        let vm = PlaybackViewModel()
        vm.isPlaying = true
        func post(_ type: AVAudioSession.InterruptionType) {
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
        }
        post(.began)
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.isPlaying == false)
        #expect(vm.wasPlayingBeforeInterruption == true)

        post(.began)
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.wasPlayingBeforeInterruption == true)
        #expect(vm.isHandlingAudioInterruption == true)
    }

    /// recordFailure attaches the most recent breadcrumbs and honours its cap.
    @Test func failureReportsAreCapped() {
        RemoteCommandDiagnostics.resetForTesting()
        for i in 0..<(RemoteCommandDiagnostics.failureCap + 2) {
            RemoteCommandDiagnostics.recordFailure(domain: "Test", code: i, message: "m\(i)")
        }
        #expect(RemoteCommandDiagnostics.failureCount == RemoteCommandDiagnostics.failureCap)
        #expect(RemoteCommandDiagnostics.recent.count <= RemoteCommandDiagnostics.recentCap)
        RemoteCommandDiagnostics.resetForTesting()
    }
}
#endif
