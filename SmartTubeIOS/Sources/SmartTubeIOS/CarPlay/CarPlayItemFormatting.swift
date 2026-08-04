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
}
