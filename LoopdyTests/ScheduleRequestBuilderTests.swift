import Foundation
import Testing
@testable import Loopdy

struct ScheduleRequestBuilderTests {
    @Test func repeatingWeekdaysBuildsReadableRequestWithoutSymbolSyntax() throws {
        let input = ScheduleInput.repeating(
            days: [.monday, .tuesday, .wednesday, .thursday, .friday],
            time: time(8, 0),
            timeZoneID: "America/Chicago"
        )

        let request = try ScheduleRequestBuilder.request(for: input)

        #expect(request == "Every weekday at 8:00 AM America/Chicago")
        #expect(!request.contains("*"))
    }

    @Test func pickerSchedulesCoverDailySelectedWeekdaysWeeklyMonthlyAndOnce() throws {
        #expect(try ScheduleRequestBuilder.request(for: .daily(time: time(9, 30), timeZoneID: "America/Chicago")) == "Every day at 9:30 AM America/Chicago")
        #expect(try ScheduleRequestBuilder.request(for: .repeating(days: [.monday, .wednesday, .friday], time: time(16, 5), timeZoneID: "America/Chicago")) == "Every Monday, Wednesday, and Friday at 4:05 PM America/Chicago")
        #expect(try ScheduleRequestBuilder.request(for: .weekly(day: .sunday, time: time(12, 0), timeZoneID: "America/Chicago")) == "Every Sunday at 12:00 PM America/Chicago")
        #expect(try ScheduleRequestBuilder.request(for: .monthly(day: 1, time: time(7, 15), timeZoneID: "America/Chicago")) == "Every month on the 1st at 7:15 AM America/Chicago")
        #expect(try ScheduleRequestBuilder.request(for: .once(date: date(2099, 9, 4, 8, 0), timeZoneID: "America/Chicago")) == "Once on September 4, 2099 at 8:00 AM America/Chicago")
    }

    @Test func nonexistentWallClockTimeUsesNextValidOccurrence() throws {
        let next = try ScheduleRequestBuilder.nextRun(
            for: .daily(time: time(2, 30), timeZoneID: "America/Chicago"),
            after: date(2026, 3, 7, 12, 0)
        )

        #expect(next == date(2026, 3, 8, 3, 0))
    }

    @Test func ambiguousWallClockTimeUsesFirstOccurrence() throws {
        let next = try ScheduleRequestBuilder.nextRun(
            for: .daily(time: time(1, 30), timeZoneID: "America/Chicago"),
            after: isoDate("2026-11-01T05:00:00Z")
        )

        #expect(next == isoDate("2026-11-01T06:30:00Z"))
    }

    @Test func hermesSaveRequestRejectsOnceDateInThePast() {
        let input = ScheduleInput.once(
            date: Date.now.addingTimeInterval(-60),
            timeZoneID: "America/Chicago"
        )

        #expect(throws: ScheduledTasksError.dateMustBeInFuture) {
            try ScheduleRequestBuilder.hermesRequest(for: input)
        }
    }

    @Test func compactIntervalsMustBePositive() {
        #expect(throws: ScheduledTasksError.intervalMustBePositive) {
            try ScheduleRequestBuilder.hermesRequest(for: .naturalLanguage(
                "every 0h",
                timeZoneID: "America/Chicago"
            ))
        }
        #expect(throws: ScheduledTasksError.intervalMustBePositive) {
            try ScheduleRequestBuilder.hermesRequest(for: .naturalLanguage(
                "every -3h",
                timeZoneID: "America/Chicago"
            ))
        }
    }

    @Test func validatedHermesRequestPreservesRequestedIANAZone() throws {
        let validated = try ScheduleRequestBuilder.validatedHermesRequest(for: .weekly(
            day: .monday,
            time: time(9, 30),
            timeZoneID: "America/Chicago"
        ))

        #expect(validated.expression == "30 9 * * 1")
        #expect(validated.requestedTimeZoneID == "America/Chicago")
    }

    @Test func commonNaturalLanguageSchedulesCompileToHermesWithoutShowingCronToTheUser() throws {
        let zone = "America/Chicago"

        #expect(try ScheduleRequestBuilder.hermesRequest(for: .naturalLanguage(
            "Every weekday at 8 AM",
            timeZoneID: zone
        )) == "0 8 * * 1-5")
        #expect(try ScheduleRequestBuilder.hermesRequest(for: .naturalLanguage(
            "Every Monday, Wednesday, and Friday at 4:05 PM",
            timeZoneID: zone
        )) == "5 16 * * 1,3,5")
        #expect(try ScheduleRequestBuilder.hermesRequest(for: .naturalLanguage(
            "Every 2 hours",
            timeZoneID: zone
        )) == "every 2h")
        #expect(throws: ScheduledTasksError.unrecognizedDescription) {
            try ScheduleRequestBuilder.hermesRequest(for: .naturalLanguage(
                "Whenever it feels useful",
                timeZoneID: zone
            ))
        }
    }

    private func time(_ hour: Int, _ minute: Int) -> DateComponents {
        DateComponents(hour: hour, minute: minute)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func isoDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
