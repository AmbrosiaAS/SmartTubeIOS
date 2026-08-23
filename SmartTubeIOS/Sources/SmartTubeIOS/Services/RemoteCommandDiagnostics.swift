import Foundation
import FirebaseCrashlytics

private let remoteLog = CrashlyticsLogger(category: "RemoteCmd")

/// Automatic diagnostics for remote-control commands (CarPlay, lock screen,
/// headphones). Added to debug in-car steering-wheel buttons that "do
/// nothing" — the manual Settings → Send Diagnostic Report button can't be
/// tapped while driving, so this records on its own.
///
/// Two channels, because Crashlytics alone could not see the rare failure:
///
/// 1. **Live breadcrumbs + auto-reports.** Every remote command is
///    breadcrumbed into Crashlytics (up to `breadcrumbCap` per session). The
///    first breadcrumb arms a one-shot flush timer; when it fires, one
///    non-fatal is recorded so the breadcrumbs ride along to the console. At
///    most `reportCap` auto-reports per *budget window*; the budget resets on
///    every `load()` so a long drive with many videos keeps reporting instead
///    of going dark after the first three minutes (which is what happened
///    before — the one-off failure was never uploaded).
///
/// 2. **Persistent session log.** Every breadcrumb is also appended to a file
///    in Application Support, uncapped by the Crashlytics buffer and
///    independent of whether any report fires. On the next app open the
///    previous session's file is attached to Crashlytics as a
///    `SmartTube.RemoteCommandSessionLog` non-fatal and deleted. Crashlytics
///    ships that event with its normal cadence (typically the following
///    launch), but nothing is lost in between: the file survives force-quits,
///    crashes and the 3-report cap.
///
/// Failures (a remote seek that did not land, etc.) go through
/// `recordFailure`, which records a dedicated non-fatal immediately (capped)
/// and carries the last few breadcrumbs as custom keys so the context is
/// readable from the issue list.
@MainActor
public enum RemoteCommandDiagnostics {
    static let breadcrumbCap = 300
    static let reportCap = 3
    static let failureCap = 5
    static let flushDelaySeconds: UInt64 = 60
    static let recentCap = 8
    static let fileLineCap = 5_000
    /// Crashlytics keeps ~64 KB of log per session; leave room for the
    /// session's own breadcrumbs.
    static let previousLogUploadBytes = 32 * 1024

    private(set) static var breadcrumbCount = 0
    private(set) static var reportCount = 0
    private(set) static var failureCount = 0
    private static var flushTask: Task<Void, Never>?
    private(set) static var recent: [String] = []

    // MARK: - Session file

    private static var sessionBootstrapped = false
    private static var sessionFile: FileHandle?
    private static var sessionFileURL: URL?
    private static var fileLineCount = 0
    private static let sessionStartedAt = Date()

    /// File persistence is off under the unit-test host: XCTest/swift-testing
    /// runs share the simulator's Application Support and would otherwise
    /// upload each other's "previous sessions" into Crashlytics.
    nonisolated static let persistenceEnabled: Bool = NSClassFromString("XCTestCase") == nil

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var logDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("RemoteCommandLogs", isDirectory: true)
    }

    /// Call once at launch (AppEntry does, right after Firebase is configured):
    /// uploads any previous session's log, then opens this session's file.
    /// Safe to call again; only the first call does anything. `log()` also
    /// calls it lazily so a missed call never loses data.
    public static func bootstrapSession() {
        guard !sessionBootstrapped else { return }
        sessionBootstrapped = true
        guard persistenceEnabled, let dir = logDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            remoteLog.error("[remote] could not create log dir: \(error.localizedDescription)")
            return
        }
        uploadPreviousSessionLogs(in: dir)
        openSessionFile(in: dir)
    }

    private static func openSessionFile(in dir: URL) {
        let stamp = timestamp.string(from: sessionStartedAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("session-\(stamp)-\(CrashlyticsLogger.sessionReportID).log")
        let header = "# SmartTube remote-command session log\n# started=\(timestamp.string(from: sessionStartedAt)) report_id=\(CrashlyticsLogger.sessionReportID)\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8)) else {
            remoteLog.error("[remote] could not create session log file")
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            sessionFile = handle
            sessionFileURL = url
        } catch {
            remoteLog.error("[remote] could not open session log file: \(error.localizedDescription)")
        }
    }

    /// Attaches the most recent previous session's log to Crashlytics as a
    /// non-fatal (tail of `previousLogUploadBytes`), summarises any older ones,
    /// and deletes them all.
    private static func uploadPreviousSessionLogs(in dir: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              !urls.isEmpty else { return }
        let files = urls
            .filter { $0.pathExtension == "log" }
            .sorted { (lhs, rhs) in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
        guard let newest = files.last else { return }
        let crashlytics = Crashlytics.crashlytics()

        for url in files {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let commandLines = lines.filter { !$0.hasPrefix("#") }
            let first = commandLines.first.map(String.init) ?? "-"
            let last = commandLines.last.map(String.init) ?? "-"

            if url == newest {
                // Attach the tail as breadcrumbs of this session so they show up
                // in the event's log panel.
                let tail = data.count > previousLogUploadBytes ? data.suffix(previousLogUploadBytes) : data[...]
                let tailText = String(decoding: tail, as: UTF8.self)
                crashlytics.log("[prev-session] ---- begin \(url.lastPathComponent) (\(commandLines.count) lines, \(data.count) bytes) ----")
                for line in tailText.split(separator: "\n", omittingEmptySubsequences: true) {
                    crashlytics.log("[prev-session] \(line)")
                }
                crashlytics.log("[prev-session] ---- end ----")
            }

            crashlytics.setCustomValue(url.lastPathComponent, forKey: "prev_session_file")
            crashlytics.setCustomValue(String(commandLines.count), forKey: "prev_session_lines")
            crashlytics.setCustomValue(String(first.prefix(200)), forKey: "prev_session_first")
            crashlytics.setCustomValue(String(last.prefix(200)), forKey: "prev_session_last")
            let error = NSError(
                domain: "SmartTube.RemoteCommandSessionLog",
                code: url == newest ? 1 : 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Remote-command log from previous session \(url.lastPathComponent) (\(commandLines.count) lines\(url == newest ? "" : ", summary only"))"]
            )
            remoteLog.recordNonFatal(error, userInfo: [:])
        }
    }

    private static func appendToFile(_ line: String) {
        guard let handle = sessionFile, fileLineCount < fileLineCap else { return }
        fileLineCount += 1
        do {
            try handle.write(contentsOf: Data((line + "\n").utf8))
            if fileLineCount == fileLineCap {
                try handle.write(contentsOf: Data("# line cap \(fileLineCap) reached — further lines dropped\n".utf8))
            }
        } catch {
            // Diagnostics must never take the player down. Stop writing.
            sessionFile = nil
        }
    }

    // MARK: - Breadcrumbs

    /// Breadcrumb a remote-command event. Always goes to the session file and
    /// the recent ring; goes to Crashlytics until the per-session cap.
    static func log(_ message: @autoclosure () -> String) {
        bootstrapSession()
        let msg = message()
        let stamped = "\(timestamp.string(from: Date())) \(msg)"
        appendToFile(stamped)
        recent.append(stamped)
        if recent.count > recentCap { recent.removeFirst(recent.count - recentCap) }

        guard breadcrumbCount < breadcrumbCap else { return }
        breadcrumbCount += 1
        remoteLog.notice("[remote] \(msg)")
        if breadcrumbCount == breadcrumbCap {
            remoteLog.notice("[remote] breadcrumb cap \(breadcrumbCap) reached — suppressing further Crashlytics breadcrumbs this session (session file continues)")
        }
        armFlush()
    }

    /// Re-arms the auto-report budget. Called from `PlaybackViewModel.load()`
    /// so each video gets its own window of up to `reportCap` reports.
    static func resetReportBudget(reason: String) {
        guard reportCount > 0 else { return }
        log("report budget reset (\(reason)) after \(reportCount) reports")
        reportCount = 0
    }

    /// Records a failure non-fatal right away (capped at `failureCap` per
    /// session) with the last `recentCap` breadcrumbs attached as custom keys.
    /// Use for "the command arrived but the player did not do it" situations.
    static func recordFailure(domain: String, code: Int, message: String, info: [String: String] = [:]) {
        log("FAILURE \(domain)(\(code)): \(message)")
        guard failureCount < failureCap else { return }
        failureCount += 1
        var userInfo = info
        userInfo["remote_failure_index"] = String(failureCount)
        userInfo["remote_breadcrumbs"] = String(breadcrumbCount)
        for (i, line) in recent.enumerated() {
            userInfo["remote_recent_\(i + 1)"] = String(line.prefix(240))
        }
        let error = NSError(domain: domain, code: code,
                            userInfo: [NSLocalizedDescriptionKey: message])
        remoteLog.recordNonFatal(error, userInfo: userInfo)
    }

    private static func armFlush() {
        guard reportCount < reportCap, flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: flushDelaySeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            reportCount += 1
            flushTask = nil
            var userInfo: [String: String] = [
                "remote_breadcrumbs": String(breadcrumbCount),
                "auto_report_index": String(reportCount),
            ]
            for (i, line) in recent.enumerated() {
                userInfo["remote_recent_\(i + 1)"] = String(line.prefix(240))
            }
            let error = NSError(
                domain: "SmartTube.RemoteCommandDiagnostics",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey:
                    "Auto remote-command diagnostic #\(reportCount) (\(breadcrumbCount) breadcrumbs this session)"]
            )
            remoteLog.recordNonFatal(error, userInfo: userInfo)
        }
    }

    /// Test hook — static state would otherwise leak between unit tests.
    static func resetForTesting() {
        flushTask?.cancel()
        flushTask = nil
        breadcrumbCount = 0
        reportCount = 0
        failureCount = 0
        recent = []
    }
}
