import Foundation
import SmartTubeIOSCore

// MARK: - CarPlayItemFormatting

/// Pure string formatting for CarPlay list rows. Kept free of CarPlay imports
/// so it compiles (and unit-tests) on every platform.
enum CarPlayItemFormatting {

    /// Second line of a video row: "Channel · 12:34", degrading gracefully when
    /// either part is missing. Live streams show "LIVE" instead of a duration.
    static func detailText(for video: Video) -> String {
        let channel = video.channelTitle
        let duration = video.isLive ? "LIVE" : video.formattedDuration
        switch (channel.isEmpty, duration.isEmpty) {
        case (false, false): return "\(channel) · \(duration)"
        case (false, true):  return channel
        case (true, false):  return duration
        case (true, true):   return ""
        }
    }

    /// The window of queue rows shown on a rotary head unit: up to `contextRows`
    /// already-played rows above the current video (so the driver can see where
    /// they are), then the up-next tail, capped at `rowCap` rows total. The
    /// window is pulled back from the end so a current video near the tail
    /// still yields a full window.
    static func queueWindow(count: Int, currentIndex: Int, rowCap: Int, contextRows: Int = 2) -> Range<Int> {
        guard count > 0, rowCap > 0 else { return 0..<0 }
        let clampedCurrent = max(0, min(currentIndex, count - 1))
        let start = max(0, min(clampedCurrent - contextRows, count - rowCap))
        let end = min(count, start + rowCap)
        return start..<end
    }
}
