import AVFoundation
import os
#if canImport(UIKit)
import UIKit
import MediaPlayer
#endif
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

/// Seconds skipped by every remote seek command: the CarPlay/lock-screen skip
/// buttons (badge + actual seek) AND the next/previous-track commands, which are
/// deliberately remapped to relative seeks — see setupRemoteCommandCenter().
let remoteSkipInterval: TimeInterval = 15

// File-scope factory — deliberately nonisolated so MPMediaItemArtwork can invoke the
// returned closure from MediaPlayer's internal serial queue without triggering the
// Swift 6 actor-isolation assertion (_swift_task_checkIsolatedSwift → EXC_BREAKPOINT).
// An inline closure defined inside a @MainActor method inherits @MainActor isolation
// even when it only captures a value-type snapshot; extracting it here breaks that.
#if canImport(UIKit)
private func makeNonisolatedArtworkProvider(image: UIImage) -> (CGSize) -> UIImage {
    { _ in image }
}
#endif

// MARK: - Now Playing (lock screen + Dynamic Island)

#if canImport(UIKit)
extension PlaybackViewModel {

    func setupAudioSessionObserver() {
        audioSessionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                // System (phone call, Siri, etc.) took the audio session — note we
                // were playing so we can resume when it ends.
                playerLog.notice("[interruption] began — pausing player")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.isHandlingAudioInterruption = true
                    self.player.pause()
                    self.isPlaying = false
                    self.updateNowPlayingPlayback()
                }
            case .ended:
                let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                playerLog.notice("[interruption] ended — shouldResume=\(options.contains(.shouldResume))")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        playerLog.error("[interruption] setActive failed: \(error.localizedDescription)")
                    }
                    if options.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                        self.player.rate = Float(self.settings.playbackSpeed)
                        self.isPlaying = true
                        self.updateNowPlayingPlayback()
                    }
                    self.isHandlingAudioInterruption = false
                    self.wasPlayingBeforeInterruption = false
                }
            @unknown default:
                break
            }
        }
    }

    func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        // Remove any existing targets first so this function is safe to call
        // multiple times (e.g. early in loadAsync AND at readyToPlay) without
        // accumulating duplicate handlers.
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.seekForwardCommand.removeTarget(nil)
        center.seekBackwardCommand.removeTarget(nil)

        RemoteCommandDiagnostics.log("setupRemoteCommandCenter (AVPlayer VM)")

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("play at t=\(Int(currentTime))s")
                player.rate = Float(settings.playbackSpeed)
                isPlaying = true
                updateNowPlayingPlayback()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("pause at t=\(Int(currentTime))s")
                player.pause()
                isPlaying = false
                updateNowPlayingPlayback()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("togglePlayPause at t=\(Int(currentTime))s")
                togglePlayPause()
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: remoteSkipInterval)]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? remoteSkipInterval
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("skipForward interval=\(interval)s t=\(Int(currentTime))s pending=\(pendingSeekTarget.map { Int($0).description } ?? "nil")")
                seekRelative(seconds: interval)
            }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: remoteSkipInterval)]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? remoteSkipInterval
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("skipBackward interval=\(interval)s t=\(Int(currentTime))s pending=\(pendingSeekTarget.map { Int($0).description } ?? "nil")")
                seekRelative(seconds: -interval)
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("changePlaybackPosition to=\(Int(position))s from t=\(Int(currentTime))s")
                seek(to: position)
            }
            return .success
        }
        // Next/previous-track are deliberately ±15 s seeks, NOT video navigation:
        // CarPlay steering-wheel skip buttons (and AirPods presses) arrive as these
        // commands, and in-car the wanted behavior is repeated presses accumulating
        // N × 15 s within the current video. Always enabled — a seek is valid even
        // when no queue/history exists (queue navigation remains available in-app).
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("nextTrack → +\(Int(remoteSkipInterval))s t=\(Int(currentTime))s pending=\(pendingSeekTarget.map { Int($0).description } ?? "nil")")
                seekRelative(seconds: remoteSkipInterval)
            }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("previousTrack → -\(Int(remoteSkipInterval))s t=\(Int(currentTime))s pending=\(pendingSeekTarget.map { Int($0).description } ?? "nil")")
                seekRelative(seconds: -remoteSkipInterval)
            }
            return .success
        }
        // Some head units deliver their seek buttons as seekForward/seekBackward
        // (scan begin/end pairs) rather than skip or track commands. These were
        // never registered, so such buttons silently did nothing. Treat "begin"
        // as a single ±15 s skip; "end" is logged for diagnosis but ignored.
        center.seekForwardCommand.addTarget { [weak self] event in
            let type = (event as? MPSeekCommandEvent)?.type
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("seekForward(\(type == .beginSeeking ? "begin" : "end")) t=\(Int(currentTime))s")
                if type == .beginSeeking { seekRelative(seconds: remoteSkipInterval) }
            }
            return .success
        }
        center.seekBackwardCommand.addTarget { [weak self] event in
            let type = (event as? MPSeekCommandEvent)?.type
            Task { @MainActor [weak self] in
                guard let self else { return }
                RemoteCommandDiagnostics.log("seekBackward(\(type == .beginSeeking ? "begin" : "end")) t=\(Int(currentTime))s")
                if type == .beginSeeking { seekRelative(seconds: -remoteSkipInterval) }
            }
            return .success
        }
    }

    func updateNowPlayingInfo() {
        let video = playerInfo?.video ?? currentVideo
        guard let video else {
            nowPlayingInfoCache = [:]
            setNowPlayingInfo(nil)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.channelTitle,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue),
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: video.isLive),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: publishablePlaybackRate),
        ]
        if let known = publishableDuration(for: video) {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: known)
        }
        applyChapterMetadata(to: &info)
        nowPlayingInfoCache = info

        // Artwork — capture the current image by value so the MPMediaItemArtwork closure
        // never captures self. MediaPlayer calls the closure on its private serial queue;
        // capturing self (a @MainActor-isolated type) causes Swift 6 to assert actor
        // isolation via dispatch_assert_queue and throw EXC_BREAKPOINT (fix238).
        if let thumbURL = video.thumbnailURL {
            let snapshot: UIImage = cachedArtwork ?? UIImage()
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600),
                                             requestHandler: makeNonisolatedArtworkProvider(image: snapshot))
            nowPlayingInfoCache[MPMediaItemPropertyArtwork] = artwork

            // Kick off fetch only when the video changes to avoid redundant network hits.
            if cachedArtworkVideoID != video.id {
                cachedArtworkVideoID = video.id
                cachedArtwork = nil
                Task { [weak self, url = thumbURL, videoID = video.id] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: data) else { return }
                    await MainActor.run { [weak self] in
                        guard let self, self.cachedArtworkVideoID == videoID else { return }
                        self.cachedArtwork = image
                        // Update the artwork key in the cache with the real image. Use the
                        // nonisolated factory so MediaPlayer can call the closure from its
                        // internal background queue without hitting the Swift 6 actor-isolation
                        // assertion (same fix as the initial artwork registration above).
                        self.nowPlayingInfoCache[MPMediaItemPropertyArtwork] =
                            MPMediaItemArtwork(boundsSize: image.size,
                                               requestHandler: makeNonisolatedArtworkProvider(image: image))
                        self.setNowPlayingInfo(self.nowPlayingInfoCache)
                    }
                }
            }
        }

        // next/previousTrackCommand stay always-enabled — they are ±15 s seek
        // buttons (see setupRemoteCommandCenter), not queue navigation, so they
        // must NOT be gated on hasNext/hasPrevious here.

        setNowPlayingInfo(nowPlayingInfoCache)
    }

    func updateNowPlayingPlayback() {
        nowPlayingInfoCache[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: currentTime)
        nowPlayingInfoCache[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: publishablePlaybackRate)
        // Keep the duration current: it starts as the catalogue value and is
        // replaced by AVPlayer's exact one once the item is ready (see
        // publishableDuration).
        let video = playerInfo?.video ?? currentVideo
        if let known = publishableDuration(for: video),
           (nowPlayingInfoCache[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue != known {
            nowPlayingInfoCache[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: known)
        }
        // The current chapter changes as time advances, so it has to be refreshed
        // here (every 3 s via refreshNowPlayingElapsedTimeIfNeeded) rather than only
        // when the video's metadata changes.
        applyChapterMetadata(to: &nowPlayingInfoCache)
        setNowPlayingInfo(nowPlayingInfoCache)
    }

    /// Publishes the current chapter as Now Playing metadata.
    ///
    /// CarPlay cannot draw chapter notches on its progress bar — CPNowPlayingTemplate
    /// exposes no progress-bar API at all — so metadata is the only way to tell the
    /// driver which section is playing. The CarPlay Now Playing template renders
    /// three text lines (verified in the simulator): title, artist, and a smaller
    /// dimmed album line that appears only when the key is set. The chapter name goes
    /// on the album line so it reads as a subtitle and the artist line stays the
    /// channel name.
    ///
    /// `ChapterNumber`/`ChapterCount` are also published in case the system surfaces
    /// them (e.g. a "3 of 26" indicator); CarPlay was not observed to render anything
    /// from them, but they are correct information and cost nothing.
    private func applyChapterMetadata(to info: inout [String: Any]) {
        guard !chapters.isEmpty else {
            info.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
            info.removeValue(forKey: MPNowPlayingInfoPropertyChapterCount)
            info.removeValue(forKey: MPNowPlayingInfoPropertyChapterNumber)
            return
        }
        info[MPNowPlayingInfoPropertyChapterCount] = NSNumber(value: chapters.count)
        guard let current = currentChapter,
              let index = chapters.firstIndex(where: { $0.id == current.id }) else {
            // Chaptered video, but playback is before the first chapter starts —
            // drop any stale name rather than leaving the previous one on screen.
            info.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
            info.removeValue(forKey: MPNowPlayingInfoPropertyChapterNumber)
            return
        }
        info[MPNowPlayingInfoPropertyChapterNumber] = NSNumber(value: index)
        info[MPMediaItemPropertyAlbumTitle] = current.title
    }

    /// Duration to advertise to Now Playing, or nil when none can honestly be
    /// claimed.
    ///
    /// Prefers AVPlayer's own duration, but falls back to the catalogue duration
    /// carried on the `Video` (the same value the CarPlay list row displays).
    /// That fallback is what makes the progress bar appear immediately: stream
    /// resolution can take ~90 s on a cold start, and without any duration key
    /// the system renders NO bar and NO position at all — the screen just shows a
    /// title and transport glyphs, which reads as "the position display is
    /// broken". The catalogue value is accurate to the second for normal videos
    /// and is overwritten by AVPlayer's once the item is ready.
    ///
    /// Live streams get nil: they advertise MPNowPlayingInfoPropertyIsLiveStream
    /// and must never be given a finite bar.
    private func publishableDuration(for video: Video?) -> TimeInterval? {
        if duration > 0 { return duration }
        guard let video, !video.isLive, let catalogue = video.duration, catalogue > 0 else { return nil }
        return catalogue
    }

    /// Interval between periodic elapsed-time publishes to MPNowPlayingInfoCenter.
    /// The system extrapolates the progress bar from the last (elapsed, rate) pair,
    /// so ticking the info center every 0.5 s (the time-observer cadence) would be
    /// pure overhead — each nowPlayingInfo write is a comparatively expensive XPC
    /// round-trip to mediaremoted. 3 s keeps the bar honest within one glance after
    /// anything that invalidates the extrapolation (seeks, speed changes) while
    /// writing at 1/6 the tick rate.
    static let nowPlayingElapsedRefreshInterval: TimeInterval = 3

    /// Throttled elapsed-time refresh, called from the 0.5 s periodic time observer
    /// (after its isScrubbing / isSkippingSegment / isQualityChangePending guards,
    /// so a publish can never fight a scrub). Without a periodic correction the
    /// info center only hears from us on discrete events, and any stale
    /// (elapsed, rate) pair — e.g. from a publish that raced a seek — persists
    /// until the next user action.
    func refreshNowPlayingElapsedTimeIfNeeded(now: Date = Date()) {
        // Nothing published (pre-load, or after clearNowPlayingInfo() on stop):
        // publishing would resurrect a ghost Now Playing entry containing only
        // elapsed/rate. Wait for the next full updateNowPlayingInfo().
        guard !nowPlayingInfoCache.isEmpty else { return }
        guard now.timeIntervalSince(lastNowPlayingElapsedRefresh) >= Self.nowPlayingElapsedRefreshInterval else { return }
        lastNowPlayingElapsedRefresh = now
        updateNowPlayingPlayback()
    }

    func clearNowPlayingInfo() {
        cachedArtwork = nil
        cachedArtworkVideoID = nil
        nowPlayingInfoCache = [:]
        setNowPlayingInfo(nil)
    }

    /// Writes to `MPNowPlayingInfoCenter` directly on `@MainActor` (= main thread).
    /// Do NOT use DispatchQueue.main.async here — dispatching async from @MainActor
    /// creates a new GCD block that may lack the proper queue-specific context that
    /// MediaPlayer's internal accessQueue asserts, causing EXC_BREAKPOINT.
    /// Since every caller is already @MainActor-isolated this call is always
    /// synchronous on the main thread.
    private func setNowPlayingInfo(_ info: [String: Any]?) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // playbackState is a SEPARATE property from the info dictionary, and the
        // info dictionary alone is not enough: without this, CarPlay's Now Playing
        // template shows the ▶ (paused) glyph and refuses to extrapolate the
        // progress bar from (elapsed, rate), so the bar latches on the first value
        // it ever saw and only jumps when a seek forces a refresh. Traced in the
        // CarPlay simulator: the app wrote elapsed 246→308 with rate 1.0 every 3 s
        // while the screen sat frozen at 3:36 for a minute.
        //
        // It must come from the PLAYER, not from `isPlaying`. `isPlaying` is an
        // intent flag set the moment playback is requested, so deriving the state
        // from it claimed ".playing" while the stream was still resolving — and
        // because the system extrapolates the bar from (elapsed, rate), the bar
        // then advanced smoothly for audio that was never running. That is the
        // "bar moves but there is no sound" report: a bar that guesses instead of
        // reporting. `actualPlaybackState` only says .playing when AVPlayer is
        // actually rolling.
        center.playbackState = info == nil ? .stopped : actualPlaybackState
    }

    /// What the player is *actually* doing, for MPNowPlayingInfoCenter.
    ///
    /// MediaPlayer has no "buffering" state, so a stall or a not-yet-resolved
    /// stream reports `.paused`: the bar holds still and the head unit shows the
    /// ▶ glyph, which is the truth — nothing is playing yet.
    private var actualPlaybackState: MPNowPlayingPlaybackState {
        switch player.timeControlStatus {
        case .playing:                      return .playing
        case .paused:                       return .paused
        case .waitingToPlayAtSpecifiedRate: return .paused
        @unknown default:                   return .paused
        }
    }

    /// The rate to publish. Paired with `actualPlaybackState`: the system
    /// extrapolates position as `elapsed + rate × wall-clock`, so publishing a
    /// non-zero rate while the player is stalled is what makes the bar drift away
    /// from reality. Zero unless audio is genuinely rolling.
    var publishablePlaybackRate: Double {
        player.timeControlStatus == .playing ? Double(player.rate) : 0
    }
}
#endif
