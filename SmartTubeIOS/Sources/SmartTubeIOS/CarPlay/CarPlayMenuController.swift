#if os(iOS) && canImport(CarPlay)
import CarPlay
import UIKit
import os
import SmartTubeIOSCore

// MARK: - CarPlayMenuController

/// Builds and drives the CarPlay template hierarchy:
///
///     Root list ── Now Playing ──────────► CPNowPlayingTemplate
///               ├─ History ─────────────► video list ─► play + CPNowPlayingTemplate
///               └─ Watch Later ─────────► video list ─► play + CPNowPlayingTemplate
///
/// Only stock CPListTemplate / CPNowPlayingTemplate templates are used, so the
/// whole UI is navigable with a rotary controller (e.g. Mazda MZD Connect's
/// commander knob) — no touch-only elements anywhere.
@MainActor
final class CarPlayMenuController {

    private let interfaceController: CPInterfaceController
    private let log = Logger(subsystem: "com.void.smarttube.app", category: "CarPlay")

    /// Rows per list. MZD Connect renders long lists slowly and scrolling a
    /// rotary dial through hundreds of rows is unusable anyway.
    private static let maxRows = 30

    private enum Source {
        case history
        case watchLater

        var title: String {
            switch self {
            case .history:    return "History"
            case .watchLater: return "Watch Later"
            }
        }
    }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    // MARK: - Root menu

    func installRootTemplate() {
        let root = CPListTemplate(title: "SmartTube", sections: [makeRootSection()])
        interfaceController.setRootTemplate(root, animated: true) { [log] _, error in
            if let error {
                log.error("[CarPlay] setRootTemplate failed: \(error.localizedDescription)")
            }
        }
    }

    private func makeRootSection() -> CPListSection {
        let nowPlaying = CPListItem(text: "Now Playing",
                                    detailText: nil,
                                    image: Self.symbolImage("play.circle.fill"))
        nowPlaying.accessoryType = .disclosureIndicator
        nowPlaying.handler = { [weak self] _, completion in
            self?.showNowPlaying()
            completion()
        }

        let history = CPListItem(text: "History",
                                 detailText: nil,
                                 image: Self.symbolImage("clock.arrow.circlepath"))
        history.accessoryType = .disclosureIndicator
        history.handler = { [weak self] _, completion in
            self?.pushVideoList(source: .history)
            completion()
        }

        let watchLater = CPListItem(text: "Watch Later",
                                    detailText: nil,
                                    image: Self.symbolImage("bookmark.circle.fill"))
        watchLater.accessoryType = .disclosureIndicator
        watchLater.handler = { [weak self] _, completion in
            self?.pushVideoList(source: .watchLater)
            completion()
        }

        return CPListSection(items: [nowPlaying, history, watchLater])
    }

    // MARK: - Video lists

    private func pushVideoList(source: Source) {
        let template = CPListTemplate(title: source.title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { [weak self] in
            await self?.populate(template, source: source)
        }
    }

    private func populate(_ template: CPListTemplate, source: Source) async {
        guard let api = CarPlayBridge.shared.api else {
            template.emptyViewTitleVariants = ["SmartTube is unavailable"]
            template.emptyViewSubtitleVariants = ["Open the app on your iPhone once, then reconnect."]
            return
        }
        // The auth token normally reaches the API through AppEntry's SwiftUI
        // onChange handlers, but those never fire when the app is launched
        // straight from the head unit without the phone scene ever attaching.
        // Push the current credentials explicitly before fetching.
        if let auth = CarPlayBridge.shared.authService {
            await api.setAuthToken(auth.accessToken)
            await api.setSAPISID(auth.sapisid)
        }
        do {
            let group: VideoGroup
            switch source {
            case .history:    group = try await api.fetchHistory()
            case .watchLater: group = try await api.fetchPlaylistVideos(playlistId: "WL")
            }
            let videos = Array(group.videos.prefix(Self.maxRows))
            log.notice("[CarPlay] \(source.title, privacy: .public) loaded \(videos.count) videos")
            guard !videos.isEmpty else {
                template.emptyViewTitleVariants = ["No videos"]
                template.emptyViewSubtitleVariants = ["Sign in on your iPhone to see your \(source.title)."]
                return
            }
            let items = videos.map { makeVideoItem($0) }
            template.updateSections([CPListSection(items: items)])
            loadThumbnails(items: items, videos: videos)
        } catch {
            log.error("[CarPlay] \(source.title, privacy: .public) fetch failed: \(error.localizedDescription)")
            template.emptyViewTitleVariants = ["Couldn't load \(source.title)"]
            template.emptyViewSubtitleVariants = [error.localizedDescription]
        }
    }

    private func makeVideoItem(_ video: Video) -> CPListItem {
        var detail = video.channelTitle
        let duration = video.formattedDuration
        if !duration.isEmpty {
            detail = detail.isEmpty ? duration : "\(detail) · \(duration)"
        }
        let item = CPListItem(text: video.title, detailText: detail)
        item.playingIndicatorLocation = .trailing
        item.handler = { [weak self] _, completion in
            CarPlayBridge.shared.play(video: video)
            self?.showNowPlaying()
            completion()
        }
        return item
    }

    /// Fetches each row's thumbnail and attaches it to the list item.
    /// One Task per row so a slow CDN response never blocks the others; the
    /// resize is trivial (≤ 320×180 source) and stays on the main actor because
    /// CPListItem is not Sendable.
    private func loadThumbnails(items: [CPListItem], videos: [Video]) {
        let maxSize = CPListItem.maximumImageSize
        for (item, video) in zip(items, videos) {
            let candidates = ([video.thumbnailURL] + video.thumbnailFallbackURLs).compactMap { $0 }
            Task { @MainActor in
                for url in candidates {
                    guard let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
                          let image = UIImage(data: data)
                    else { continue }
                    item.setImage(Self.scaled(image, toFit: maxSize))
                    break
                }
            }
        }
    }

    // MARK: - Now Playing

    private func showNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        guard interfaceController.topTemplate !== nowPlaying else { return }
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
        } else {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: - Image helpers

    private static func symbolImage(_ name: String) -> UIImage? {
        UIImage(systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium))
    }

    private static func scaled(_ image: UIImage, toFit maxSize: CGSize) -> UIImage {
        let scale = min(maxSize.width / image.size.width,
                        maxSize.height / image.size.height,
                        1)
        guard scale < 1 else { return image }
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
#endif
