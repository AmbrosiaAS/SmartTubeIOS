import Foundation

private let remoteLog = CrashlyticsLogger(category: "RemoteCmd")

/// Automatic, capped diagnostics for remote-control commands (CarPlay,
/// lock screen, headphones). Added to debug in-car steering-wheel buttons
/// that "do nothing" — the manual Settings → Send Diagnostic Report button
/// can't be tapped while driving, so this uploads on its own.
///
/// Every remote command is breadcrumbed (up to `breadcrumbCap` per app
/// session). The first breadcrumb arms a one-shot flush timer; when it fires,
/// one non-fatal is recorded so Crashlytics actually uploads the session's
/// breadcrumb buffer (breadcrumbs alone never upload — they ride along with
/// an event, typically on the next app launch). At most `reportCap`
/// auto-reports per session keeps Firebase usage negligible on a test phone.
@MainActor
enum RemoteCommandDiagnostics {
    static let breadcrumbCap = 300
    static let reportCap = 3
    static let flushDelaySeconds: UInt64 = 60

    private(set) static var breadcrumbCount = 0
    private(set) static var reportCount = 0
    private static var flushTask: Task<Void, Never>?

    /// Breadcrumb a remote-command event. No-op once the session cap is hit.
    static func log(_ message: @autoclosure () -> String) {
        guard breadcrumbCount < breadcrumbCap else { return }
        breadcrumbCount += 1
        remoteLog.notice("[remote] \(message())")
        if breadcrumbCount == breadcrumbCap {
            remoteLog.notice("[remote] breadcrumb cap \(breadcrumbCap) reached — suppressing further remote breadcrumbs this session")
        }
        armFlush()
    }

    private static func armFlush() {
        guard reportCount < reportCap, flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: flushDelaySeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            reportCount += 1
            flushTask = nil
            let error = NSError(
                domain: "SmartTube.RemoteCommandDiagnostics",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey:
                    "Auto remote-command diagnostic #\(reportCount) (\(breadcrumbCount) breadcrumbs this session)"]
            )
            remoteLog.recordNonFatal(error, userInfo: [
                "remote_breadcrumbs": String(breadcrumbCount),
                "auto_report_index": String(reportCount),
            ])
        }
    }

    /// Test hook — static state would otherwise leak between unit tests.
    static func resetForTesting() {
        flushTask?.cancel()
        flushTask = nil
        breadcrumbCount = 0
        reportCount = 0
    }
}
