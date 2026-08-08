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

// MARK: - Queue window

@Suite("CarPlay queue row window")
struct CarPlayQueueWindowTests {

    @Test("short queue shows everything")
    func shortQueue() {
        #expect(CarPlayItemFormatting.queueWindow(count: 5, currentIndex: 2, rowCap: 30) == 0..<5)
    }

    @Test("current video mid-queue keeps two rows of context above it")
    func midQueue() {
        #expect(CarPlayItemFormatting.queueWindow(count: 100, currentIndex: 40, rowCap: 30) == 38..<68)
    }

    @Test("current video at the head starts the window at zero")
    func head() {
        #expect(CarPlayItemFormatting.queueWindow(count: 100, currentIndex: 0, rowCap: 30) == 0..<30)
    }

    @Test("current video near the tail pulls the window back for a full page")
    func tail() {
        #expect(CarPlayItemFormatting.queueWindow(count: 100, currentIndex: 99, rowCap: 30) == 70..<100)
    }

    @Test("index one shows only one row of context")
    func nearHead() {
        #expect(CarPlayItemFormatting.queueWindow(count: 100, currentIndex: 1, rowCap: 30) == 0..<30)
    }

    @Test("empty queue yields an empty window")
    func emptyQueue() {
        #expect(CarPlayItemFormatting.queueWindow(count: 0, currentIndex: 0, rowCap: 30).isEmpty)
    }

    @Test("out-of-range current index is clamped instead of crashing")
    func outOfRange() {
        #expect(CarPlayItemFormatting.queueWindow(count: 10, currentIndex: 42, rowCap: 30) == 0..<10)
        #expect(CarPlayItemFormatting.queueWindow(count: 10, currentIndex: -3, rowCap: 30) == 0..<10)
    }
}
