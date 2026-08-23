import AVFoundation
import os
#if canImport(UIKit)
import MediaPlayer
#endif
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Transport Controls & Scrubbing

extension PlaybackViewModel {

    public func togglePlayPause() {
        if videoEnded {
            videoEnded = false
            seek(to: 0)
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
            showControls()
            #if canImport(UIKit)
            updateNowPlayingPlayback()
            #endif
            return
        }
        if isPlaying { player.pause() } else { player.rate = Float(settings.playbackSpeed) }
        isPlaying.toggle()
        showControls()
        #if canImport(UIKit)
        updateNowPlayingPlayback()
        #endif
    }

    // MARK: - Scrubbing (slider drag)

    /// Called when the user starts dragging the progress slider.
    public func beginScrubbing() {
        // Guard against the spurious onEditingChanged(true) that SwiftUI's Slider
        // fires right after commitScrub() triggers a binding re-evaluation.
        let sinceCommit = Date.now.timeIntervalSince(lastCommitScrubTime)
        guard sinceCommit > 0.5 else {
            playerLog.debug("[scrub] beginScrubbing IGNORED (spurious, \(String(format: "%.3f", sinceCommit))s since commit — threshold=0.5s)")
            return
        }
        playerLog.debug("[scrub] beginScrubbing at \(String(format: "%.1f", self.currentTime))s — sinceCommit=\(String(format: "%.3f", sinceCommit))s isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
        seekDebounceTask?.cancel()
        isScrubbing = true
        scrubTime = currentTime
        playerLog.debug("[scrub] beginScrubbing done — isScrubbing=\(self.isScrubbing)")
    }

    /// Called on every incremental slider position update while dragging.
    /// Only updates the local `scrubTime` — does NOT seek AVPlayer, preventing
    /// rapid-seek stalls. Seeking happens only on `commitScrub`.
    public func updateScrub(to time: TimeInterval) {
        scrubTime = time
    }

    /// Called when the user releases the slider. Issues a single precise seek.
    public func commitScrub() {
        // SwiftUI's Slider fires onEditingChanged(false) on initialization (when the
        // view first renders), before the user has ever touched it. Guard here so that
        // spurious call doesn't (a) call showControls() at load time, or (b) poison
        // lastCommitScrubTime and block the user's first real scrub attempt via the
        // debounce guard in beginScrubbing().
        guard isScrubbing else { return }
        seekDebounceTask?.cancel()  // release-seek supersedes any pending debounce
        let target = scrubTime
        playerLog.debug("[scrub] commitScrub to \(String(format: "%.1f", target))s — isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
        lastCommitScrubTime = .now
        isScrubbing = false
        seek(to: target)
        showControls()
        playerLog.debug("[scrub] commitScrub done — isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
    }

    /// Issues a seek to the given time. Does NOT show controls — callers that
    /// want the overlay to appear (user-initiated gestures) must call
    /// `showControls()` themselves after this.
    /// - Parameter remote: true when the seek was requested by a remote command
    ///   (CarPlay, lock screen, headphones). Remote seeks breadcrumb their
    ///   outcome and report a failure non-fatal if the seek does not land, so
    ///   an in-car "the button did nothing" shows up with the player's state.
    public func seek(to time: TimeInterval) {
        seek(to: time, remote: false)
    }

    public func seek(to time: TimeInterval, remote: Bool) {
        // Record the in-flight target so overlapping relative seeks chain off it
        // (see seekRelative). Only the completion of the *latest* seek clears it —
        // superseded seeks must not reset the chain early.
        pendingSeekTarget = time
        #if canImport(UIKit)
        if remote {
            RemoteCommandDiagnostics.log("seek req target=\(Int(time))s item=\(remoteSeekItemState) rate=\(player.rate)")
        }
        #endif
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasLatest = self.pendingSeekTarget == time
                self.currentTime = time
                if wasLatest { self.pendingSeekTarget = nil }
                #if canImport(UIKit)
                if remote { self.reportRemoteSeekOutcome(target: time, finished: finished, wasLatest: wasLatest) }
                // CarPlay / lock screen extrapolate the playback position from the
                // last elapsed-time value pushed to MPNowPlayingInfoCenter — without
                // a push here their progress bars drift after every seek.
                self.updateNowPlayingPlayback()
                #endif
            }
        }
    }

    public func seekRelative(seconds: TimeInterval) {
        seekRelative(seconds: seconds, remote: false)
    }

    public func seekRelative(seconds: TimeInterval, remote: Bool) {
        let base = pendingSeekTarget ?? currentTime
        var target = max(0, base + seconds)
        if duration > 0 { target = min(target, duration) }
        seek(to: target, remote: remote)
        showControls()
    }

    #if canImport(UIKit)
    /// One-word description of the current item's readiness, for breadcrumbs.
    var remoteSeekItemState: String {
        guard let item = player.currentItem else { return "nil" }
        switch item.status {
        case .readyToPlay: return "ready"
        case .failed:      return "failed"
        case .unknown:     return "unknown"
        @unknown default:  return "other"
        }
    }

    /// Breadcrumbs how a remote seek actually ended, and records a failure
    /// non-fatal when the latest seek did not land. A superseded seek
    /// (`finished == false` because a newer seek replaced it) is normal during
    /// rapid presses and is logged but not reported.
    func reportRemoteSeekOutcome(target: TimeInterval, finished: Bool, wasLatest: Bool) {
        let actual = player.currentTime().seconds
        let drift = actual.isFinite ? abs(actual - target) : .infinity
        RemoteCommandDiagnostics.log("seek done target=\(Int(target))s finished=\(finished) latest=\(wasLatest) actual=\(actual.isFinite ? Int(actual).description : "nan")s item=\(remoteSeekItemState)")
        guard wasLatest else { return }
        if !finished || drift > 2 {
            RemoteCommandDiagnostics.recordFailure(
                domain: "SmartTube.RemoteSeekFailed",
                code: finished ? 2 : 1,
                message: finished
                    ? "Remote seek to \(Int(target))s landed at \(Int(actual))s (item \(remoteSeekItemState))"
                    : "Remote seek to \(Int(target))s did not finish (item \(remoteSeekItemState))",
                info: [
                    "seek_target_s": String(Int(target)),
                    "seek_actual_s": actual.isFinite ? String(Int(actual)) : "nan",
                    "seek_item_state": remoteSeekItemState,
                    "seek_player_rate": String(player.rate),
                    "seek_video_id": currentVideo?.id ?? "nil",
                ])
        }
    }
    #endif

    public func setPlaybackSpeed(_ speed: Double) {
        // Setting player.rate to a non-zero value on a paused AVPlayer restarts
        // playback — only apply the rate while actively playing.
        if isPlaying {
            player.rate = Float(speed)
        }
    }

    /// Called when the user begins a long-press on the video surface (controls hidden).
    /// Temporarily boosts playback to 2× until `endHoldSpeed()` is called.
    public func beginHoldSpeed() {
        guard isPlaying, !isHoldingToSpeed else { return }
        isHoldingToSpeed = true
        player.rate = 2.0
        playerLog.notice("[hold-speed] began — boosting to 2×")
    }

    /// Called when the user lifts their finger after a long-press speed boost.
    /// Restores playback to the configured speed.
    public func endHoldSpeed() {
        guard isHoldingToSpeed else { return }
        isHoldingToSpeed = false
        if isPlaying {
            player.rate = Float(settings.playbackSpeed)
        }
        playerLog.notice("[hold-speed] ended — restored to \(self.settings.playbackSpeed)×")
    }
}
