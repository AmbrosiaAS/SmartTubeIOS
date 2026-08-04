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
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: isPlaying ? Double(player.rate) : 0.0),
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        }
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
        nowPlayingInfoCache[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: isPlaying ? Double(player.rate) : 0.0)
        setNowPlayingInfo(nowPlayingInfoCache)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
#endif
