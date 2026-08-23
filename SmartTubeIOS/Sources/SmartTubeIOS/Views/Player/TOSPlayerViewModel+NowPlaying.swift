#if os(iOS)
import UIKit
import MediaPlayer
import SmartTubeIOSCore

private let tosNowPlayingLog = CrashlyticsLogger(category: "TOSPlayer")

// File-scope factory — deliberately nonisolated so MPMediaItemArtwork can invoke the
// returned closure from MediaPlayer's internal serial queue without triggering the
// Swift 6 actor-isolation assertion. Mirrors PlaybackViewModel+NowPlaying.swift's
// identical helper — see that file's doc comment for the full story.
private func makeNonisolatedArtworkProvider(image: UIImage) -> (CGSize) -> UIImage {
    { _ in image }
}

// MARK: - Now Playing (lock screen + Dynamic Island + headphone controls)
//
// #283: TOSPlayerViewModel previously had zero MPNowPlayingInfoCenter/
// MPRemoteCommandCenter integration — confirmed live on device that the lock
// screen widget showed stale info from a previous AVPlayer session, with
// non-functional controls. This gives TOS player correct metadata and working
// play/pause/skip/seek/next/previous while the app is foregrounded or
// minimized to TOSMiniPlayerView. It does NOT add background audio or system
// PiP — both were investigated and found not feasible without a hybrid
// AVPlayer-handoff approach the user explicitly rejected (see task-283).

extension TOSPlayerViewModel {

    func setupRemoteCommandCenter() {
        tosNowPlayingLog.notice("[NowPlaying] setupRemoteCommandCenter() called")
        // Owned through RemoteCommandRegistry (see PlaybackViewModel's version):
        // installing replaces the AVPlayer VM's handlers, and only this instance
        // can remove its own. Safe to call multiple times (every loadEmbed).
        RemoteCommandDiagnostics.log("setupRemoteCommandCenter (TOS VM \(remoteOwner.shortDescription))")
        let center = MPRemoteCommandCenter.shared()
        RemoteCommandRegistry.shared.install(owner: remoteOwner) { reg in
            reg.add(center.playCommand) { [weak self] _ in
                RemoteCommandDiagnostics.log("TOS play")
                self?.play()
                return .success
            }
            reg.add(center.pauseCommand) { [weak self] _ in
                RemoteCommandDiagnostics.log("TOS pause")
                self?.pause()
                return .success
            }
            reg.add(center.togglePlayPauseCommand) { [weak self] _ in
                guard let self else { return .success }
                RemoteCommandDiagnostics.log("TOS togglePlayPause state=\(self.playerState)")
                if self.playerState == .playing { self.pause() } else { self.play() }
                return .success
            }
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: remoteSkipInterval)]
            reg.add(center.skipForwardCommand) { [weak self] event in
                guard let self else { return .success }
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? remoteSkipInterval
                RemoteCommandDiagnostics.log("TOS skipForward interval=\(interval)s t=\(Int(self.currentTime))s")
                self.seekRelative(seconds: interval)
                return .success
            }
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: remoteSkipInterval)]
            reg.add(center.skipBackwardCommand) { [weak self] event in
                guard let self else { return .success }
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? remoteSkipInterval
                RemoteCommandDiagnostics.log("TOS skipBackward interval=\(interval)s t=\(Int(self.currentTime))s")
                self.seekRelative(seconds: -interval)
                return .success
            }
            reg.add(center.changePlaybackPositionCommand) { [weak self] event in
                guard let self,
                      let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .success }
                RemoteCommandDiagnostics.log("TOS changePlaybackPosition to=\(Int(position))s from t=\(Int(self.currentTime))s")
                self.pendingSeekTarget = position
                self.currentTime = position
                self.seekTo(position)
                self.updateNowPlayingPlayback()
                return .success
            }
            // Next/previous-track are ±15 s seeks, NOT video navigation — mirrors
            // PlaybackViewModel.setupRemoteCommandCenter(): CarPlay steering-wheel
            // skip buttons and AirPods presses arrive as these commands, and repeated
            // presses must accumulate N × 15 s within the current video. Always
            // enabled — a seek is valid even with no queue/history.
            center.nextTrackCommand.isEnabled = true
            reg.add(center.nextTrackCommand) { [weak self] _ in
                guard let self else { return .success }
                RemoteCommandDiagnostics.log("TOS nextTrack → +\(Int(remoteSkipInterval))s t=\(Int(self.currentTime))s")
                self.seekRelative(seconds: remoteSkipInterval)
                return .success
            }
            center.previousTrackCommand.isEnabled = true
            reg.add(center.previousTrackCommand) { [weak self] _ in
                guard let self else { return .success }
                RemoteCommandDiagnostics.log("TOS previousTrack → -\(Int(remoteSkipInterval))s t=\(Int(self.currentTime))s")
                self.seekRelative(seconds: -remoteSkipInterval)
                return .success
            }
        }
    }

    /// Removes this VM's remote-command handlers (only if it still owns them).
    func releaseRemoteCommands(reason: String) {
        RemoteCommandRegistry.shared.remove(owner: remoteOwner, reason: reason)
    }

    func updateNowPlayingInfo() {
        tosNowPlayingLog.notice("[NowPlaying] updateNowPlayingInfo — title='\(videoTitle)' channel='\(channelTitle)' duration=\(String(format: "%.1f", duration))s")
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: videoTitle,
            MPMediaItemPropertyArtist: channelTitle,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: playerState == .playing ? 1.0 : 0.0),
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        }
        nowPlayingInfoCache = info

        // Artwork — capture the current image by value so the MPMediaItemArtwork
        // closure never captures self (see makeNonisolatedArtworkProvider's doc
        // comment / PlaybackViewModel+NowPlaying.swift's fix238 for why).
        if let thumbnailURL {
            let snapshot: UIImage = cachedArtwork ?? UIImage()
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600),
                                             requestHandler: makeNonisolatedArtworkProvider(image: snapshot))
            nowPlayingInfoCache[MPMediaItemPropertyArtwork] = artwork

            if cachedArtworkVideoID != videoId {
                cachedArtworkVideoID = videoId
                cachedArtwork = nil
                Task { [weak self, url = thumbnailURL, videoID = videoId] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: data) else { return }
                    await MainActor.run { [weak self] in
                        guard let self, self.cachedArtworkVideoID == videoID else { return }
                        self.cachedArtwork = image
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
        nowPlayingInfoCache[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: playerState == .playing ? 1.0 : 0.0)
        setNowPlayingInfo(nowPlayingInfoCache)
    }

    func clearNowPlayingInfo() {
        cachedArtwork = nil
        cachedArtworkVideoID = nil
        nowPlayingInfoCache = [:]
        setNowPlayingInfo(nil)
    }

    /// Writes to `MPNowPlayingInfoCenter` directly on `@MainActor` (main thread).
    /// Do NOT dispatch async here — see PlaybackViewModel+NowPlaying.swift's
    /// identical doc comment for why that causes an EXC_BREAKPOINT.
    private func setNowPlayingInfo(_ info: [String: Any]?) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // Same reason as PlaybackViewModel+NowPlaying's identical line: without an
        // explicit playbackState the lock screen shows a paused glyph and a frozen
        // progress bar regardless of the rate in the info dictionary.
        center.playbackState = info == nil ? .stopped : (playerState == .playing ? .playing : .paused)
    }
}
#endif
