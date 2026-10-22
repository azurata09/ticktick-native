import Foundation
import Testing
@testable import TickTickNative

@Suite("日付とOAuth")
struct TaskAndOAuthTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-23T03:00:00Z")! }

    @Test func scheduledDayBoundaries() {
        let cases: [(String, DayBucket)] = [
            ("2026-10-22T14:59:59Z", .overdue),
            ("2026-10-22T15:00:00Z", .today),
            ("2026-10-23T14:59:59.999Z", .today),
            ("2026-10-23T15:00:00Z", .other),
            ("2026-10-23T09:00:00+0900", .today)
        ]
        for (date, expected) in cases {
            let task = TickTask(id: "a", projectId: "p", title: "sample", dueDate: date)
            #expect(TaskSchedule(calendar: calendar).bucket(task, now: now) == expected)
        }
    }

    @Test func allDayDatesDoNotShiftWithTimeZone() {
        var losAngeles = calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let noon = ISO8601DateFormatter().date(from: "2026-10-23T19:00:00Z")!
        let task = TickTask(id: "a", projectId: "p", title: "sample", isAllDay: true, dueDate: "2026-10-23T00:00:00+0900")
        #expect(TaskSchedule(calendar: losAngeles).bucket(task, now: noon) == .today)
    }

    @Test func periodsUndatedAndCompletedTasks() {
        var task = TickTask(id: "a", projectId: "p", title: "sample")
        #expect(TaskSchedule(calendar: calendar).bucket(task, now: now) == .unscheduled)
        task.startDate = "2026-10-22T00:00:00+0900"
        task.dueDate = "2026-10-24T00:00:00+0900"
        #expect(TaskSchedule(calendar: calendar).bucket(task, now: now) == .today)
        task.status = 2
        #expect(TaskSchedule(calendar: calendar).bucket(task, now: now) == .other)
        task.status = -1
        #expect(TaskSchedule(calendar: calendar).bucket(task, now: now) == .other)
        task.status = 0
        task.dueDate = "not-a-date"
        #expect(TaskSchedule(calendar: calendar).bucket(task, now: now) == .invalidDate)
        task.dueDate = "2026-10-21T00:00:00+0900"
        #expect(TaskSchedule(calendar: calendar).bucket(task, now: now) == .invalidDate)
    }

    @Test func daylightSavingDayHasCalendarBoundaries() {
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = ISO8601DateFormatter().date(from: "2026-03-08T18:00:00Z")!
        let task = TickTask(id: "a", projectId: "p", title: "sample", dueDate: "2026-03-09T06:59:59Z")
        #expect(TaskSchedule(calendar: calendar).bucket(task, now: now) == .today)
        let tomorrow = TickTask(id: "b", projectId: "p", title: "sample", dueDate: "2026-03-09T07:00:00Z")
        #expect(TaskSchedule(calendar: calendar).bucket(tomorrow, now: now) == .other)
    }

    @Test func callbackRejectsTamperingAndDuplicateParameters() throws {
        let valid = URL(string: "http://127.0.0.1:49217/callback?code=a%2Bb&state=expected")!
        #expect(try OAuthFlow.code(from: valid, state: "expected") == "a+b")
        let invalid = [
            "http://127.0.0.1:49217/callback?code=a&state=wrong",
            "http://127.0.0.1:49217/callback?code=a&state=expected&state=expected",
            "http://127.0.0.1:49217/callback?code=a&code=b&state=expected",
            "ticktick-native://other/callback?code=a&state=expected",
            "https://oauth/callback?code=a&state=expected",
            "http://127.0.0.1:49217/callback?code=a&state=expected&error=access_denied",
            "http://127.0.0.1:49217/callback?state=expected",
            "http://127.0.0.1:49217/callback?code=a&state=expected#unexpected"
        ]
        for raw in invalid {
            #expect(throws: TickTickError.self) {
                try OAuthFlow.code(from: URL(string: raw)!, state: "expected")
            }
        }
    }

    @Test func authorizationRequestsReadOnlyAndFormEscapesReservedCharacters() {
        let url = OAuthFlow.authorizationURL(clientID: "sample-client", state: "random-state")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "scope" }?.value == "tasks:read")
        #expect(items.first { $0.name == "redirect_uri" }?.value == OAuthFlow.redirectURI)
        #expect(items.first { $0.name == "response_type" }?.value == "code")
        #expect(String(data: OAuthFlow.form(["code": "a+b &=日本語"]), encoding: .utf8) == "code=a%2Bb%20%26%3D%E6%97%A5%E6%9C%AC%E8%AA%9E")
    }
}
