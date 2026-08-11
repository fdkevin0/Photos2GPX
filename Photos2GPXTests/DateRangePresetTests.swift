import XCTest
@testable import Photos2GPX

final class DateRangePresetTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// 2026-08-13T15:30:00Z
    private let now = Date(timeIntervalSince1970: 1_786_635_000)

    func testTodayCoversASingleDay() {
        let interval = DateRangePreset.today.interval(now: now, calendar: calendar)
        XCTAssertEqual(calendar.startOfDay(for: now), interval.start)
        XCTAssertEqual(interval.duration, 86_400 - 1, accuracy: 1)
    }

    func testYesterdayEndsBeforeToday() {
        let interval = DateRangePreset.yesterday.interval(now: now, calendar: calendar)
        XCTAssertLessThan(interval.end, calendar.startOfDay(for: now))
        XCTAssertEqual(interval.duration, 86_400 - 1, accuracy: 1)
    }

    func testLastSevenDaysSpansSevenDays() {
        let interval = DateRangePreset.last7Days.interval(now: now, calendar: calendar)
        XCTAssertEqual(interval.duration, 7 * 86_400 - 1, accuracy: 1)
    }

    func testAllPresetsProduceForwardIntervals() {
        for preset in DateRangePreset.allCases {
            let interval = preset.interval(now: now, calendar: calendar)
            XCTAssertLessThan(interval.start, interval.end, "\(preset.title) is inverted")
        }
    }
}
