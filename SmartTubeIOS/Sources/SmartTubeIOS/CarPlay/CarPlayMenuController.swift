#if os(iOS) && canImport(CarPlay)
import CarPlay
import UIKit
import os
import SmartTubeIOSCore

// MARK: - CarPlayMenuController

/// Builds and drives the CarPlay template hierarchy:
///
///     Root list ── Now Playing ──────────► CPNowPlayingTemplate ─► Queue list
///               ├─ Queue ───────────────► Queue list ─► jump + CPNowPlayingTemplate
///               ├─ History ─────────────► video list ─► play + CPNowPlayingTemplate
///               └─ Watch Later ─────────► video list ─► play + CPNowPlayingTemplate
///
/// Only stock CPListTemplate / CPNowPlayingTemplate templates are used, so the
/// whole UI is navigable with a rotary controller (e.g. Mazda MZD Connect's
/// commander knob) — no touch-only elements anywhere. The queue is reachable
/// two ways on purpose: the Now Playing "Queue" (Up Next) button, and a root
/// menu row in case a head unit's knob focus skips the Now Playing buttons.
@MainActor
final class CarPlayMenuController: NSObject {

    private let interfaceController: CPInterfaceController
    private let log = Logger(subsystem: "com.void.smarttube.app", category: "CarPlay")

    /// Rows per list. MZD Connect renders long lists slowly and scrolling a
    /// rotary dial through hundreds of rows is unusable anyway.
    private static let maxRows = 30

    /// Rows per list while the car reports limited UI (vehicle in motion).
    /// Head units enforce caps as low as 12 in motion and silently truncate —
    /// and CPListTemplate.maximumItemCount is known to report 500 regardless —
    /// so we cap ourselves and keep the highest-value rows on top.
    private static let maxRowsLimited = 12

    /// Tracks the car's limited-UI state; delegate fires when driving starts/stops.
    private var sessionConfiguration: CPSessionConfiguration?

    /// True while the "nothing playing" alert is on screen. CarPlay permits only
    /// one presented template at a time and rejects a second one.
    private var isPresentingAlert = false

    /// Effective row cap for whatever the car currently allows.
    private var rowCap: Int {
        let limited = sessionConfiguration?.limitedUserInterfaces.contains(.lists) ?? false
        return min(limited ? Self.maxRowsLimited : Self.maxRows,
                   CPListTemplate.maximumItemCount)
    }

    private enum Source: String {
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
        super.init()
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = "Queue"
        nowPlaying.add(self)
    }

    /// Called by the scene delegate when the head unit disconnects.
    /// CPNowPlayingTemplate.shared outlives this controller, so the observer
    /// must be detached explicitly (deinit is nonisolated and can't touch it).
    func disconnect() {
        CPNowPlayingTemplate.shared.remove(self)
        sessionConfiguration = nil
    }

    // MARK: - Root menu

    func installRootTemplate() {
        let root = CPListTemplate(title: "SmartTube", sections: [makeRootSection()])
        interfaceController.setRootTemplate(root, animated: true) { [weak self, log] success, error in
            if let error {
                log.error("[CarPlay] setRootTemplate failed: \(error.localizedDescription)")
            }
            // Connecting the car mid-listen should land on the Now Playing
            // screen, not the menu — matches every other CarPlay audio app.
            if success, CarPlayBridge.shared.isPlaying {
                self?.showNowPlaying()
            }
            if success { self?.runTestScenarioIfRequested() }
        }
    }

    // MARK: - Test hooks

    /// Runs a scripted template scenario named by
    /// `--uitesting-carplay-scenario=<name>`, and logs the outcome under
    /// `[CarPlayScenario]`.
    ///
    /// This exists because the simulator's CarPlay display cannot be driven
    /// programmatically: `simctl` has no input injection for an external
    /// display, accessibility snapshots don't cover it, and synthetic clicks
    /// need a macOS Automation grant that isn't always available. Driving the
    /// template stack from inside the app makes these flows testable from a
    /// plain `simctl launch`, and makes race-dependent bugs deterministic
    /// rather than something you have to tap fast enough to hit.
    private func runTestScenarioIfRequested() {
        let prefix = "--uitesting-carplay-scenario="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return }
        let scenario = String(arg.dropFirst(prefix.count))
        log.notice("[CarPlayScenario] running '\(scenario, privacy: .public)'")

        switch scenario {
        case "double-alert":
            // Regression guard for the crash in
            // SmartTube-2026-08-07-195350.ips: presenting the "nothing playing"
            // alert while one is already presented was rejected by CarPlay and,
            // with a nil completion block, raised as an uncaught NSException.
            // Two presents in quick succession reproduce it deterministically.
            // Expected now: the first presents, the second is suppressed, and
            // the app survives.
            showNowPlaying()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.showNowPlaying()
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.showNowPlaying()
                self?.log.notice("[CarPlayScenario] double-alert survived — no uncaught exception")
            }

        case "queue-twice":
            // The queue template must not be pushed twice: a duplicate push is
            // rejected and would crash the same way.
            pushQueueList()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.pushQueueList()
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.log.notice("[CarPlayScenario] queue-twice survived — no uncaught exception")
            }

        case "play-watch-later-first":
            // Reproduces the real complaint: phone locked, app selected on the
            // head unit, first Watch Later row picked — playback never starts.
            // Runs the same code path as the row handler in makeVideoItem, so it
            // needs no pointer input and works with the screen locked.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await CarPlayBridge.shared.refreshAuthIfNeeded()
                guard let api = CarPlayBridge.shared.api else {
                    log.error("[CarPlayScenario] no api — bridge never configured")
                    return
                }
                do {
                    let group = try await api.fetchPlaylistVideos(playlistId: "WL")
                    guard let first = group.videos.first else {
                        log.error("[CarPlayScenario] Watch Later is empty")
                        return
                    }
                    log.notice("[CarPlayScenario] picking id=\(first.id, privacy: .public) title=\(first.title, privacy: .public)")
                    CarPlayBridge.shared.play(video: first)
                    self.showNowPlaying(assumePlayback: true)
                } catch {
                    log.error("[CarPlayScenario] Watch Later fetch failed: \(error.localizedDescription, privacy: .public)")
                }
            }

        default:
            log.error("[CarPlayScenario] unknown scenario '\(scenario, privacy: .public)'")
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

        let queue = CPListItem(text: "Queue",
                               detailText: nil,
                               image: Self.symbolImage("list.triangle"))
        queue.accessoryType = .disclosureIndicator
        queue.handler = { [weak self] _, completion in
            self?.pushQueueList()
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

        return CPListSection(items: [nowPlaying, queue, history, watchLater])
    }

    // MARK: - Video lists

    private func pushVideoList(source: Source) {
        let template = CPListTemplate(title: source.title, sections: [])
        template.userInfo = source.rawValue
        template.emptyViewTitleVariants = ["Loading…"]
        push(template, label: source.title)
        Task { [weak self] in
            await self?.populate(template, source: source)
        }
    }

    private func populate(_ template: CPListTemplate, source: Source) async {
        guard CarPlayBridge.shared.api != nil else {
            showUnavailableState(on: template)
            return
        }
        // On a head-unit-only launch the SwiftUI scene never attaches, so the
        // token must be pushed (and possibly refreshed) explicitly here.
        await CarPlayBridge.shared.refreshAuthIfNeeded()
        guard let api = CarPlayBridge.shared.api else {
            showUnavailableState(on: template)
            return
        }
        do {
            let group: VideoGroup
            switch source {
            case .history:    group = try await api.fetchHistory()
            case .watchLater: group = try await api.fetchPlaylistVideos(playlistId: "WL")
            }
            let videos = Array(group.videos.prefix(rowCap))
            log.notice("[CarPlay] \(source.title, privacy: .public) loaded \(videos.count) videos")
            guard !videos.isEmpty else {
                showEmptyState(on: template,
                               title: "No videos",
                               subtitle: "Sign in on your iPhone to see your \(source.title).")
                return
            }
            let items = videos.map { makeVideoItem($0, in: videos) }
            template.updateSections([CPListSection(items: items)])
            loadThumbnails(items: items, videos: videos)
        } catch {
            log.error("[CarPlay] \(source.title, privacy: .public) fetch failed: \(error.localizedDescription)")
            showEmptyState(on: template,
                           title: "Couldn't load \(source.title)",
                           subtitle: error.localizedDescription)
        }
    }

    /// Swaps a list's placeholder for a terminal empty state. Setting the
    /// emptyView variants alone is not enough: CarPlay only re-renders the
    /// empty view when the sections change, so a template still showing the
    /// "Loading…" placeholder would otherwise show it forever.
    private func showEmptyState(on template: CPListTemplate, title: String, subtitle: String) {
        template.emptyViewTitleVariants = [title]
        template.emptyViewSubtitleVariants = [subtitle]
        template.updateSections([])
    }

    /// Shown when the app's services were never registered — the phone side
    /// has to run once before the head unit can fetch anything.
    private func showUnavailableState(on template: CPListTemplate) {
        showEmptyState(on: template,
                       title: "SmartTube is unavailable",
                       subtitle: "Open the app on your iPhone once, then reconnect.")
    }

    /// - Parameter videos: the whole visible list, needed only so the playing
    ///   glyph can be moved between rows (see `markSelectedPlaying`).
    private func makeVideoItem(_ video: Video, in videos: [Video]) -> CPListItem {
        let item = CPListItem(text: video.title,
                              detailText: CarPlayItemFormatting.detailText(for: video))
        // isPlaying drives our glyph logic (see playingGlyph), not CarPlay's
        // own indicator, which doesn't render reliably on this head unit.
        item.isPlaying = video.id == CarPlayBridge.shared.currentVideoId
        item.handler = { [weak self] selected, completion in
            self?.log.notice("[CarPlay] row selected id=\(video.id, privacy: .public)")
            // Adds this video to the queue and plays it (see CarPlayBridge).
            CarPlayBridge.shared.play(video: video)
            self?.markSelectedPlaying(selected, listVideos: videos)
            self?.showNowPlaying(assumePlayback: true)
            completion()
        }
        return item
    }

    /// Moves the playing mark to `selected`: every other row gets its
    /// thumbnail (back), the selected row gets the playing glyph.
    /// `listVideos` must be the same array the visible list was built from.
    private func markSelectedPlaying(_ selected: CPSelectableListItem, listVideos: [Video]) {
        guard let template = interfaceController.topTemplate as? CPListTemplate else { return }
        let items = template.sections.flatMap { $0.items.compactMap { $0 as? CPListItem } }
        for other in items {
            other.isPlaying = false
        }
        (selected as? CPListItem)?.isPlaying = true
        // Re-runs the thumbnail pass: restores artwork on the previously
        // playing row and stamps the glyph on the new one.
        loadThumbnails(items: items, videos: listVideos)
    }

    /// The image shown on the currently playing row instead of its thumbnail.
    ///
    /// CPListItem's own playing indicator is unusable in practice (verified in
    /// the CarPlay simulator): with `.trailing` it's covered by the head unit's
    /// scroll chevrons, with `.leading` it's displaced by the thumbnail, and on
    /// an imageless row no leading slot is allocated at all. A glyph in the
    /// image slot renders deterministically everywhere a thumbnail would.
    private static let playingGlyph = symbolImage("speaker.wave.2.fill")

    /// Row thumbnails already fetched this session, keyed by video ID.
    ///
    /// Rows are re-imaged whenever the playing mark moves or a list is
    /// repopulated, so without this every selection would re-download a
    /// listful of thumbnails. Images are ≤ `CPListItem.maximumImageSize`, and
    /// row counts are capped, so the cache stays small.
    private var thumbnailCache: [String: UIImage] = [:]

    /// Fetches each row's thumbnail and attaches it to the list item.
    /// One Task per row so a slow CDN response never blocks the others; the
    /// resize is trivial (≤ 320×180 source) and stays on the main actor because
    /// CPListItem is not Sendable.
    ///
    /// The currently playing row gets the playing glyph, not its thumbnail —
    /// see `playingGlyph`.
    private func loadThumbnails(items: [CPListItem], videos: [Video]) {
        let maxSize = CPListItem.maximumImageSize
        for (item, video) in zip(items, videos) {
            if item.isPlaying {
                item.setImage(Self.playingGlyph)
                continue
            }
            if let cached = thumbnailCache[video.id] {
                item.setImage(cached)
                continue
            }
            let candidates = ([video.thumbnailURL] + video.thumbnailFallbackURLs).compactMap { $0 }
            Task { @MainActor [weak self] in
                for url in candidates {
                    guard let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
                          let image = UIImage(data: data)
                    else { continue }
                    let scaled = Self.scaled(image, toFit: maxSize)
                    self?.thumbnailCache[video.id] = scaled
                    // The mark may have moved onto this row while the fetch
                    // was in flight; the glyph wins.
                    if !item.isPlaying { item.setImage(scaled) }
                    break
                }
            }
        }
    }

    // MARK: - Queue

    private func pushQueueList() {
        // Only one instance of a given template may be on the stack; pushing
        // the queue from Now Playing after entering via the root Queue row
        // would otherwise crash. Pop back to the existing one instead.
        if let existing = interfaceController.templates.first(where: {
            ($0 as? CPListTemplate)?.userInfo as? String == Self.queueTemplateTag
        }) as? CPListTemplate {
            pop(to: existing, label: "Queue")
            Task { [weak self] in await self?.populateQueue(existing) }
            return
        }
        let template = CPListTemplate(title: "Queue", sections: [])
        template.userInfo = Self.queueTemplateTag
        template.emptyViewTitleVariants = ["Queue is empty"]
        template.emptyViewSubtitleVariants = ["Pick a video from History or Watch Later to start a queue."]
        push(template, label: "Queue")
        Task { [weak self] in
            await self?.populateQueue(template)
        }
    }

    private static let queueTemplateTag = "carplay.queue"

    private func populateQueue(_ template: CPListTemplate) async {
        let all = await CurrentQueueStore.shared.videos
        guard !all.isEmpty else {
            template.updateSections([])
            return
        }
        let currentIndex = CarPlayBridge.shared.currentQueueIndex ?? 0
        // Rotary-friendly window: a knob can't fling-scroll, so the cap
        // matters more here than anywhere else.
        let window = CarPlayItemFormatting.queueWindow(count: all.count,
                                                       currentIndex: currentIndex,
                                                       rowCap: rowCap)
        let start = window.lowerBound
        let end = window.upperBound
        let slice = Array(all[window])
        let items = slice.enumerated().map { offset, video -> CPListItem in
            let index = start + offset
            let item = CPListItem(text: video.title,
                                  detailText: CarPlayItemFormatting.detailText(for: video))
            item.isPlaying = index == currentIndex && CarPlayBridge.shared.hasActiveVideo
            item.handler = { [weak self, slice] selected, completion in
                CarPlayBridge.shared.playQueueItem(at: index)
                self?.markSelectedPlaying(selected, listVideos: slice)
                self?.showNowPlaying(assumePlayback: true)
                completion()
            }
            return item
        }
        // Header shows the window when the queue is longer than the row cap,
        // so a truncated list doesn't read as the whole queue.
        let header = all.count > slice.count
            ? "Showing \(start + 1)–\(end) of \(all.count)"
            : nil
        template.updateSections([CPListSection(items: items, header: header, sectionIndexTitle: nil)])
        loadThumbnails(items: items, videos: slice)
    }

    // MARK: - Now Playing

    /// - Parameter assumePlayback: pass true right after starting playback —
    ///   the bridge kicks playback off asynchronously, so `hasActiveVideo` may
    ///   not have flipped yet and the "nothing playing" alert would misfire.
    private func showNowPlaying(assumePlayback: Bool = false) {
        // An empty system Now Playing screen is a dead end on a rotary head
        // unit; explain instead when nothing has been played yet.
        guard assumePlayback || CarPlayBridge.shared.hasActiveVideo else {
            let alert = CPAlertTemplate(
                titleVariants: [
                    "Nothing is playing yet. Pick a video from History or Watch Later.",
                    "Nothing playing yet",
                ],
                actions: [
                    CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                        guard let self else { return }
                        self.isPresentingAlert = false
                        self.interfaceController.dismissTemplate(animated: true) { [log = self.log] _, error in
                            if let error { log.error("[CarPlay] dismissTemplate failed: \(error.localizedDescription)") }
                        }
                    }
                ]
            )
            // CarPlay throws "Presenting a template while a template is already
            // presented is not supported" if an alert is already up — and with a
            // nil completion block it raises that error as an UNCAUGHT NSException
            // instead of reporting it, crashing the app (confirmed in a crash
            // report: NSGenericException from CPInterfaceController
            // _handleCompletion:withSuccess:error:). Two guards: don't present a
            // second alert, and always pass a completion so any future template
            // error is delivered to us rather than thrown.
            guard !isPresentingAlert else { return }
            isPresentingAlert = true
            interfaceController.presentTemplate(alert, animated: true) { [weak self, log] _, error in
                if let error {
                    self?.isPresentingAlert = false
                    log.error("[CarPlay] presentTemplate failed: \(error.localizedDescription)")
                }
            }
            return
        }
        let nowPlaying = CPNowPlayingTemplate.shared
        guard interfaceController.topTemplate !== nowPlaying else { return }
        // Same reasoning for the push/pop pair: a nil completion turns a rejected
        // template operation into a crash. Pushing a template that is already on
        // the stack is rejected, so the contains() check matters — but the
        // completion block is the backstop for anything it doesn't anticipate
        // (e.g. two pushes racing before the first completes).
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            interfaceController.pop(to: nowPlaying, animated: true) { [log] _, error in
                if let error { log.error("[CarPlay] pop to Now Playing failed: \(error.localizedDescription)") }
            }
        } else {
            interfaceController.pushTemplate(nowPlaying, animated: true) { [log] _, error in
                if let error { log.error("[CarPlay] push Now Playing failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Template stack

    /// Pushes a template, reporting failures instead of dying on them.
    ///
    /// Never pass `completion: nil` to a CPInterfaceController operation. When
    /// CarPlay rejects one — a duplicate template, the 5-deep stack limit, or
    /// presenting over an already-presented template — and no completion block
    /// was supplied, it raises the error as an **uncaught NSException** and the
    /// app is killed with SIGABRT. A crash report confirmed exactly that. With a
    /// block, the same condition is delivered to us as an `error` we can log.
    private func push(_ template: CPTemplate, label: String) {
        interfaceController.pushTemplate(template, animated: true) { [log] _, error in
            if let error {
                log.error("[CarPlay] push \(label, privacy: .public) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pops back to a template already on the stack. Same completion-block
    /// reasoning as `push`.
    private func pop(to template: CPTemplate, label: String) {
        interfaceController.pop(to: template, animated: true) { [log] _, error in
            if let error {
                log.error("[CarPlay] pop to \(label, privacy: .public) failed: \(error.localizedDescription)")
            }
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

// MARK: - CPSessionConfigurationDelegate

extension CarPlayMenuController: CPSessionConfigurationDelegate {
    /// Fires when the car starts/stops limiting UI (typically: vehicle in
    /// motion). Repopulate the visible list so the row cap change takes
    /// effect immediately instead of the head unit silently truncating.
    nonisolated func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        Task { @MainActor in
            self.log.notice("[CarPlay] limitedUserInterfaces changed: lists=\(limitedUserInterfaces.contains(.lists))")
            guard let top = self.interfaceController.topTemplate as? CPListTemplate,
                  let tag = top.userInfo as? String else { return }
            if tag == Self.queueTemplateTag {
                await self.populateQueue(top)
            } else if let source = Source(rawValue: tag) {
                await self.populate(top, source: source)
            }
        }
    }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlayMenuController: CPNowPlayingTemplateObserver {
    /// The "Queue" (Up Next) button on the system Now Playing screen.
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            self.pushQueueList()
        }
    }
}
#endif
