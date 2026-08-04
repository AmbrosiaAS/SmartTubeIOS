import Testing
@testable import SmartTubeIOS
import SmartTubeIOSCore

// MARK: - CarPlayItemFormattingTests

@Suite("CarPlay list-row formatting")
struct CarPlayItemFormattingTests {

    @Test("channel and duration are joined with a middot")
    func channelAndDuration() {
        let video = Video(id: "a", title: "T", channelTitle: "Donut Media", duration: 754)
        #expect(CarPlayItemFormatting.detailText(for: video) == "Donut Media · 12:34")
    }

    @Test("missing duration leaves just the channel")
    func channelOnly() {
        let video = Video(id: "a", title: "T", channelTitle: "Donut Media")
        #expect(CarPlayItemFormatting.detailText(for: video) == "Donut Media")
    }

    @Test("missing channel leaves just the duration")
    func durationOnly() {
        let video = Video(id: "a", title: "T", channelTitle: "", duration: 90)
        #expect(CarPlayItemFormatting.detailText(for: video) == "1:30")
    }

    @Test("nothing available yields an empty detail line")
    func empty() {
        let video = Video(id: "a", title: "T", channelTitle: "")
        #expect(CarPlayItemFormatting.detailText(for: video).isEmpty)
    }

    @Test("live streams show LIVE instead of a duration")
    func live() {
        let video = Video(id: "a", title: "T", channelTitle: "ABC News", duration: 3600, isLive: true)
        #expect(CarPlayItemFormatting.detailText(for: video) == "ABC News · LIVE")
    }
}
