import AVFoundation
import os
#if canImport(UIKit)
import MediaPlayer
#endif
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - AVPlayer Observers

extension PlaybackViewModel {

    func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't overwrite the slider position or trigger SponsorBlock auto-seeks
                // while the user is scrubbing. Auto-seeks call seek() → showControls() →
                // scheduleControlsHide(), which cancels and restarts the 4 s hide-timer
                // every 0.5 s, preventing controls from ever auto-hiding post-scrub.
                guard !self.isScrubbing else { return }
                guard !self.sponsorBlockManager.isSkippingSegment else { return }
                // Suspend time updates during a quality-change transition: the new
                // AVPlayerItem is not yet ready and player.currentTime() may return 0
                // or a stale value. currentTime is restored by qualityItemDidBecomeReady.
                guard !self.isQualityChangePending else { return }
                self.currentTime = seconds
                self.checkSponsorSkip(at: seconds)
                self.updateCaptionCue(for: seconds)
                if self.statsForNerdsVisible { self.updateStatsSnapshot() }
                #if canImport(UIKit)
                // Placed after the guards above so a periodic Now Playing publish
                // can never fight an in-progress scrub or SponsorBlock auto-seek.
                self.refreshNowPlayingElapsedTimeIfNeeded()
                #endif
            }
        }
    }

    func setupRateObserver() {
        // KVO on player.rate so isPlaying stays in sync when the system externally
        // pauses the player (e.g. headphones removed, audio session interruption ends
        // without shouldResume). Without this, isPlaying stays true while the player
        // is actually silent, causing handleForeground() to re-start a ghost session.
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self, let newRate = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore rate changes that we ourselves triggered (load/pause/resume/stop)
                // by only acting when the player goes silent unexpectedly while we
                // believed it was playing.
                //
                // Also ignore rate→0 when currentTime is within 1 s of the total
                // duration: that's the video naturally reaching its end, not a stall.
                // In that case AVFoundation will post didPlayToEndTimeNotification
                // immediately after, which calls handlePlaybackEnd() correctly.
                // Without this guard the recovery logic seeks back by ~1 s and fights
                // the natural ending, causing repeated spurious stall reports and
                // blocking the end-of-video / autoplay-next flow (crash log confirmed
                // via Crashlytics: stall #1–4 at t=15s for a 15.3 s video).
                let nearEnd = self.duration > 0 && self.currentTime >= self.duration - 1.0
                let playerWentSilent = newRate == 0 && self.isPlaying && !self.isSwappingItem && !self.isHandlingAudioInterruption && !nearEnd
                if playerWentSilent {
                    self.isPlaying = false
                    playerLog.notice("[rateObserver] player.rate→0 while isPlaying=true — syncing isPlaying=false")
                    self.stallCount += 1
                    if self.firstRapidStallTime == nil { self.firstRapidStallTime = Date() }
                    let t = Int(self.currentTime)
                    let stallError = NSError(
                        domain: "SmartTube.PlaybackStall",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "player.rate→0 while isPlaying=true at t=\(t)s (stall #\(self.stallCount))"]
                    )
                    playerLog.recordNonFatal(stallError, userInfo: [
                        "video_id":       self.currentVideo?.id ?? "unknown",
                        "stall_at_time":  String(t),
                        "stall_count":    String(self.stallCount),
                        "video_duration": String(Int(self.duration)),
                        "stall_trigger":  "rateObserver"
                    ])
                    #if canImport(UIKit)
                    self.updateNowPlayingPlayback()
                    #endif
                    // Stall recovery: mirror the AVPlayerItemPlaybackStalled path (#193).
                    // Wait 2 s for the system to self-heal (audio route change, interruption
                    // resume, etc.), then nudge the pipeline if still stalled. Guard on
                    // !isPlaying (already set above) rather than isPlaying, and also on
                    // !isSwappingItem to avoid interfering with intentional item swaps.
                    // Capped at 3 attempts per item, same as the notification-based path.
                    let recoveryCount = self.stallCount
                    let elapsed = self.firstRapidStallTime.map { Date().timeIntervalSince($0) } ?? 0
                    let isRapidRepeat = elapsed < 30
                    if recoveryCount >= 3 && isRapidRepeat && self.exhaustiveRetryTask == nil {
                        // Rapid stall loop: seeks are re-stalling immediately because the
                        // format URL is expired or rate-limited (CDN returns the same broken
                        // URL after each seek). Escalate to exhaustiveRetry instead of
                        // another wasted seek. Guard on exhaustiveRetryTask == nil to avoid
                        // launching duplicate retries if further stalls fire during retry.
                        if let video = self.currentVideo {
                            playerLog.notice("[rateObserver] rapid stall loop — \(recoveryCount) stalls in \(Int(elapsed))s — escalating to exhaustiveRetry")
                            let loopError = NSError(
                                domain: "SmartTube.PlaybackStall",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Stall loop \(recoveryCount)× in \(Int(elapsed))s — format unrecoverable, escalating"]
                            )
                            self.exhaustiveRetryTask = Task { await self.exhaustiveRetry(video: video, originalError: loopError) }
                        }
                    } else if recoveryCount <= 3 {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            guard let self, !self.isPlaying, self.player.rate == 0,
                                  !self.isQualityChangePending, !self.isSwappingItem else { return }
                            let seekT = self.currentTime
                            playerLog.notice("[rateObserver] recovery#\(recoveryCount): seeking to \(seekT)s to flush pipeline")
                            self.player.seek(
                                to: CMTime(seconds: seekT, preferredTimescale: 600),
                                toleranceBefore: .zero,
                                toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
                            ) { [weak self] _ in
                                Task { @MainActor [weak self] in
                                    guard let self, !self.isPlaying, self.player.rate == 0 else { return }
                                    self.player.rate = Float(self.settings.playbackSpeed)
                                    self.isPlaying = true
                                    playerLog.notice("[rateObserver] recovery#\(recoveryCount): rate restored, isPlaying=true")
                                }
                            }
                        }
                    }
                } else {
                    #if canImport(UIKit)
                    // Rate changed without a stall — most importantly 0 → non-zero
                    // when playback actually begins (readyToPlay → play). Nothing
                    // else publishes that transition to MPNowPlayingInfoCenter, so
                    // the lock screen / CarPlay Now Playing kept the load-time
                    // snapshot (rate 0, elapsed ≈ load position): the system drew a
                    // Play glyph and, with rate 0, never extrapolated the progress
                    // bar — it sat frozen while audio was audibly playing. Also
                    // covers playback-speed changes applied directly to player.rate.
                    // Publish only when the reported rate would actually change:
                    // our own play/pause/toggle handlers already call
                    // updateNowPlayingPlayback() themselves, and their KVO echoes
                    // land here with a matching cached rate — skipping them avoids
                    // a redundant nowPlayingInfo write per user action.
                    let cachedRate = (self.nowPlayingInfoCache[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
                    if cachedRate != self.publishablePlaybackRate {
                        self.updateNowPlayingPlayback()
                    }
                    #endif
                }
            }
        }
    }

    #if canImport(UIKit)
    /// Republishes Now Playing whenever the player's real playback status changes.
    ///
    /// This is what keeps the head unit's progress bar honest. The bar is drawn by
    /// the system as `elapsed + rate × wall-clock` from the last values we
    /// published, so those values must change at exactly the moments audio starts
    /// and stops. `timeControlStatus` is the only property that reports those
    /// moments: play() sets `rate` to 1 up front and the status lingers at
    /// `.waitingToPlayAtSpecifiedRate` until the stream is actually rolling, with
    /// no further rate change when it finally does.
    func setupTimeControlObserver() {
        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.nowPlayingInfoCache.isEmpty else { return }
                self.updateNowPlayingPlayback()
            }
        }
    }

    func setupAirPlayObserver() {
        airPlayObserver = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, change in
            guard let self, let active = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.isAirPlaying = active
            }
        }
    }
    #endif
}
