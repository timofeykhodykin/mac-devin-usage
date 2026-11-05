import Foundation
import SQLite3
import Testing
@testable import MacDevinUsage

@Suite struct UsageParsingTests {
    /// A real `GetUserStatus` response, trimmed.
    let sample = """
    {"userStatus":{"name":"A User","email":"a@example.com","planStatus":{
      "planInfo":{"teamsTier":"TEAMS_TIER_DEVIN_PRO","planName":"Pro",
                  "billingStrategy":"BILLING_STRATEGY_QUOTA"},
      "planStart":"2026-11-05T22:09:43Z","planEnd":"2026-12-05T22:09:43Z",
      "availablePromptCredits":-1,
      "dailyQuotaRemainingPercent":79,"weeklyQuotaRemainingPercent":89,
      "overageBalanceMicros":"10000000",
      "dailyQuotaResetAtUnix":"1793952000","weeklyQuotaResetAtUnix":"1794124800"}}}
    """

    /// The `UsageError` parsing `json` throws, or nil when it parses.
    func parseError(_ json: String) -> UsageError? {
        do { _ = try UsageAPI.parse(Data(json.utf8)); return nil }
        catch let error as UsageError { return error }
        catch { return nil }
    }

    @Test func parsesGetUserStatus() throws {
        let snapshot = try UsageAPI.parse(Data(sample.utf8))
        // Percentages are *remaining*.
        #expect(snapshot.daily?.utilization == 21)
        #expect(snapshot.weekly?.utilization == 11)
        #expect(snapshot.daily?.resetsAt == Date(timeIntervalSince1970: 1_793_952_000))
        #expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1_794_124_800))
        #expect(snapshot.plan == "Pro")
    }

    @Test func omittedPercentMeansFullyUsed() throws {
        // proto3 omits zero values: a reset time with no percent is 0 remaining.
        let json = """
        {"userStatus":{"planStatus":{"planInfo":{"planName":"Pro"},
          "dailyQuotaResetAtUnix":"1793952000",
          "weeklyQuotaRemainingPercent":"50","weeklyQuotaResetAtUnix":1794124800}}}
        """
        let snapshot = try UsageAPI.parse(Data(json.utf8))
        #expect(snapshot.daily?.utilization == 100)
        #expect(snapshot.weekly?.utilization == 50)
        // int64s arrive as strings or numbers.
        #expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1_794_124_800))
    }

    @Test func percentWithoutResetHasNoResetTime() throws {
        let json = """
        {"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":10,
                                     "weeklyQuotaRemainingPercent":20}}}
        """
        let snapshot = try UsageAPI.parse(Data(json.utf8))
        #expect(snapshot.daily?.utilization == 90)
        #expect(snapshot.daily?.resetsAt == nil)
        #expect(snapshot.weekly?.resetsAt == nil)
    }

    @Test func hiddenQuotaDropsItsWindow() throws {
        let json = """
        {"userStatus":{"planStatus":{"planInfo":{"hideDailyQuota":true},
          "dailyQuotaRemainingPercent":79,"dailyQuotaResetAtUnix":"1793952000",
          "weeklyQuotaRemainingPercent":89,"weeklyQuotaResetAtUnix":"1794124800"}}}
        """
        let snapshot = try UsageAPI.parse(Data(json.utf8))
        #expect(snapshot.daily == nil)
        #expect(snapshot.weekly?.utilization == 11)
    }

    @Test func noQuotaPlanThrowsNoQuota() {
        // Credit/ACU-billed plans report neither quota.
        let json = #"{"userStatus":{"planStatus":{"planInfo":{"planName":"Teams","billingStrategy":"BILLING_STRATEGY_CREDITS"}}}}"#
        guard case .noQuota? = parseError(json) else {
            Issue.record("expected .noQuota, got \(String(describing: parseError(json)))")
            return
        }
    }

    @Test func garbageThrowsDecoding() {
        for json in ["not json", "[1,2,3]", "{}"] {
            guard case .decoding? = parseError(json) else {
                Issue.record("expected .decoding for \(json)")
                return
            }
        }
    }

    @Test func retryAfterFormats() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UsageAPI.parseRetryAfter("120", now: now) == 120)
        #expect(UsageAPI.parseRetryAfter(nil, now: now) == nil)
        let date = UsageAPI.parseRetryAfter("Mon, 12 Jan 1970 13:47:40 GMT", now: now)
        #expect(date == 60)
    }

    @Test func windowResetsToZero() {
        let now = Date()
        let past = UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(-1))
        let future = UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(60))
        #expect(past.currentUtilization(now: now) == 0)
        #expect(future.currentUtilization(now: now) == 80)
    }

    @Test func snapshotWithoutPlanStillDecodes() throws {
        let old = #"{"fetchedAt":770000000,"daily":{"utilization":5}}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.daily?.utilization == 5)
        #expect(snapshot.plan == nil)
    }
}

@Suite struct DevinCredentialsTests {
    @Test func cliTOMLParsesKeys() throws {
        let creds = try #require(DevinCredentials.parseCLI("""
        # a comment
        [windsurf]
        windsurf_api_key = "key-1"
        api_server_url = "https://api.example.com"
        """))
        #expect(creds.apiKey == "key-1")
        #expect(creds.apiServerURL == URL(string: "https://api.example.com"))
    }

    @Test func cliTOMLAcceptsAPIKeyAndSingleQuotes() throws {
        let creds = try #require(DevinCredentials.parseCLI("api_key = 'key-2'\n"))
        #expect(creds.apiKey == "key-2")
        #expect(creds.apiServerURL == DevinCredentials.defaultAPIServer)
    }

    @Test func cliTOMLFirstKeyLineWins() throws {
        let creds = try #require(DevinCredentials.parseCLI("""
        api_key = "first"
        windsurf_api_key = "second"
        """))
        #expect(creds.apiKey == "first")
    }

    @Test func cliTOMLWithoutKeyIsMissing() {
        #expect(DevinCredentials.parseCLI("api_server_url = \"https://x.example.com\"\n") == nil)
        #expect(DevinCredentials.parseCLI("") == nil)
    }

    @Test func nonHTTPSServerURLFallsBackToDefault() throws {
        let creds = try #require(DevinCredentials.parseCLI("""
        api_key = "k"
        api_server_url = "http://insecure.example.com"
        """))
        #expect(creds.apiServerURL == DevinCredentials.defaultAPIServer)
        #expect(DevinCredentials.apiServerURL("not a url") == DevinCredentials.defaultAPIServer)
        #expect(DevinCredentials.apiServerURL(nil) == DevinCredentials.defaultAPIServer)
    }

    @Test func desktopDatabaseIsRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value BLOB)",
                                  nil, nil, nil) == SQLITE_OK)
        let value = #"{"apiKey":"desktop-key","apiServerUrl":"https://desktop.example.com","other":{}}"#
        try #require(sqlite3_exec(db, "INSERT INTO ItemTable(key, value) VALUES('windsurfAuthStatus', '\(value)')",
                                  nil, nil, nil) == SQLITE_OK)

        let creds = try #require(DevinCredentials.readDesktop(database: url))
        #expect(creds.apiKey == "desktop-key")
        #expect(creds.apiServerURL == URL(string: "https://desktop.example.com"))
    }

    @Test func missingDesktopDatabaseIsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).vscdb")
        #expect(DevinCredentials.readDesktop(database: url) == nil)
    }
}

@Suite struct FormattingTests {
    @Test func barColorFollowsScale() {
        func close(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Bool {
            abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9
        }
        let stops = UsageBar.pastelStops
        #expect(close(UsageBar.rgb(at: 0), stops[0]))
        #expect(close(UsageBar.rgb(at: 1), stops[3]))
        #expect(close(UsageBar.rgb(at: 1.0 / 3), stops[1]))
        #expect(close(UsageBar.rgb(at: 1.5), stops[3]))   // clamped
        #expect(close(UsageBar.rgb(at: -1), stops[0]))
        let mid = UsageBar.rgb(at: 1.0 / 6)                // halfway green → yellow
        #expect(close(mid, ((stops[0].r + stops[1].r) / 2, (stops[0].g + stops[1].g) / 2, (stops[0].b + stops[1].b) / 2)))
    }

    @Test func absoluteResetLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 20))!
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        }
        #expect(UsageRow.absoluteReset(at(27, 23), now: now, calendar: calendar, locale: locale) == "today 23:00")
        #expect(UsageRow.absoluteReset(at(28, 1), now: now, calendar: calendar, locale: locale) == "tomorrow 01:00")
        #expect(UsageRow.absoluteReset(at(30, 12), now: now, calendar: calendar, locale: locale) == "30 Sep 12:00")
    }

    @Test func ageCounter() {
        #expect(UpdatedLabel.age(0) == "0s")
        #expect(UpdatedLabel.age(42.9) == "42s")
        #expect(UpdatedLabel.age(65) == "1m 05s")
        #expect(UpdatedLabel.age(750) == "12m 30s")
        #expect(UpdatedLabel.age(3900) == "1h 05m")
        #expect(UpdatedLabel.age(2 * 86400 + 3 * 3600) == "2d 3h")
        #expect(UpdatedLabel.age(-5) == "0s")
    }

    @Test func pressThatClosedTheDropdownIsDropped() {
        // Times from a real click at the top edge of the screen: the dropdown closed 6 ms after the press.
        #expect(MenuBarClickFix.closedWithPress(pressAt: 947648.102, closedAt: 947648.108, dropdownVisible: false))
        // Closed a second before: this press is meant to open it again.
        #expect(!MenuBarClickFix.closedWithPress(pressAt: 947646.994, closedAt: 947645.772, dropdownVisible: false))
        // Still open: SwiftUI's own toggle closes it.
        #expect(!MenuBarClickFix.closedWithPress(pressAt: 10, closedAt: 10, dropdownVisible: true))
        #expect(!MenuBarClickFix.closedWithPress(pressAt: 10, closedAt: -.infinity, dropdownVisible: false))
    }

    @Test func menuBarText() {
        let now = Date()
        let snapshot = UsageSnapshot(daily: UsageWindow(utilization: 12.6, resetsAt: now.addingTimeInterval(3600)),
                                     weekly: UsageWindow(utilization: 5, resetsAt: now.addingTimeInterval(-60)),
                                     fetchedAt: now)
        func text(_ s: UsageSnapshot?, weekly: Bool, unavailable: Bool = false) -> String {
            MenuBarLabel.text(snapshot: s, showWeekly: weekly, unavailable: unavailable, now: now)
        }
        #expect(text(snapshot, weekly: false) == "13%")
        #expect(text(snapshot, weekly: true) == "13% / 0%") // weekly window already reset
        #expect(text(snapshot, weekly: false, unavailable: true) == "?")
        #expect(text(snapshot, weekly: true, unavailable: true) == "? / ?")
        #expect(text(UsageSnapshot(daily: nil, weekly: nil, fetchedAt: now), weekly: true) == "–% / –%")
    }
}

@Suite struct UsageHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var dailyReset: Date { t0.addingTimeInterval(20 * 3600) }
    var weekReset: Date { t0.addingTimeInterval(3 * 86400) }

    func point(_ minutes: Double, d: Double?, dr: Date? = nil, w: Double?, wr: Date? = nil) -> UsagePoint {
        UsagePoint(date: t0.addingTimeInterval(minutes * 60), daily: d, dailyResetsAt: dr,
                   weekly: w, weeklyResetsAt: wr)
    }

    @Test func recordsChangesAndHeartbeats() {
        let last = point(0, d: 10, dr: dailyReset, w: 40, wr: weekReset)
        #expect(UsageHistory.shouldRecord(last, after: nil))
        #expect(!UsageHistory.shouldRecord(point(1, d: 10, dr: dailyReset, w: 40, wr: weekReset), after: last))
        #expect(UsageHistory.shouldRecord(point(1, d: 11, dr: dailyReset, w: 40, wr: weekReset), after: last))
        #expect(UsageHistory.shouldRecord(point(1, d: 10, dr: dailyReset, w: 41, wr: weekReset), after: last))
        // Same reset reported with different precision: not a change.
        #expect(!UsageHistory.shouldRecord(point(1, d: 10, dr: dailyReset.addingTimeInterval(0.3), w: 40, wr: weekReset), after: last))
        // A new window is a change even at the same percentage.
        #expect(UsageHistory.shouldRecord(point(1, d: 10, dr: dailyReset.addingTimeInterval(86400), w: 40, wr: weekReset), after: last))
        #expect(UsageHistory.shouldRecord(point(10, d: 10, dr: dailyReset, w: 40, wr: weekReset), after: last))
        #expect(!UsageHistory.shouldRecord(point(-1, d: 50, dr: dailyReset, w: 40, wr: weekReset), after: last))
        #expect(!UsageHistory.shouldRecord(point(0, d: nil, w: nil), after: nil))
    }

    @Test func fileFormatRoundTrips() throws {
        let points = [point(0, d: 10, dr: dailyReset, w: 40, wr: weekReset), point(5, d: 12.5, w: nil)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = Data()
        for p in points.reversed() {
            data.append(try encoder.encode(p))
            data.append(Data("\nnot json\n".utf8))
        }
        #expect(UsageHistory.decode(data) == points)  // garbage skipped, sorted by date
        #expect(String(data: try encoder.encode(points[1]), encoding: .utf8)?.contains("\"d\":12.5") == true)
    }

    @Test func pruneKeepsRetention() {
        let old = point(-36 * 24 * 60, d: 1, w: 1)
        let recent = point(-34 * 24 * 60, d: 1, w: 1)
        let future = point(2 * 60, d: 1, w: 1)
        #expect(UsageHistory.pruned([old, recent, future], now: t0) == [recent])
    }

    @Test func daysPerWeekFromDeltas() throws {
        let r1 = t0.addingTimeInterval(20 * 3600), r2 = t0.addingTimeInterval(44 * 3600)
        let points = [
            // The first day: 0 → 60%, weekly 10 → 18%.
            point(0, d: 0, dr: r1, w: 10, wr: weekReset),
            point(30, d: 20, dr: r1, w: 13, wr: weekReset),
            point(120, d: 60, dr: r1, w: 18, wr: weekReset),
            // Next day, seen first at 5% (that pair crosses a reset and is skipped).
            point(400, d: 5, dr: r2, w: 19, wr: weekReset),
            point(500, d: 65, dr: r2, w: 27, wr: weekReset)
        ]
        let estimate = try #require(UsageHistory.daysEstimate(points, currentWeekly: 27, now: points[4].date))
        // The day grew 60 + 60, weekly 8 + 8: 7.5 full days per week, 73 / 13.33 left.
        #expect(estimate.days == 2)
        #expect(abs(try #require(estimate.perWeek.value) - 7.5) < 1e-9)
        #expect(abs(try #require(estimate.remaining.value) - 73 / (100 / 7.5)) < 1e-9)
        // Both days agree exactly, so only rounding to whole percent is left: a few percent.
        #expect(estimate.relativeError > 0.03 && estimate.relativeError < 0.1)
        #expect(DaysLabel.text(estimate).hasPrefix("≈ 5.5 ± 0."))
        #expect(DaysLabel.text(estimate).hasSuffix(" of 7.5 ± 0.6 full days left"))
    }

    @Test func estimateShowsUpWithLittleData() throws {
        let r = dailyReset
        // Weekly moved 2 points: a range.
        let some = [point(0, d: 0, dr: r, w: 10, wr: weekReset), point(30, d: 20, dr: r, w: 12, wr: weekReset)]
        let ranged = try #require(UsageHistory.daysEstimate(some, currentWeekly: 12, now: some[1].date))
        #expect(ranged.relativeError > 0.35 && ranged.relativeError <= 0.5)
        #expect(DaysLabel.text(ranged).contains("–"))
        #expect(DaysLabel.text(ranged).hasSuffix("full days left"))

        // Weekly moved a single point: too rough to show, the tooltip has the range.
        let one = [point(0, d: 11, dr: r, w: 2, wr: weekReset), point(14, d: 15, dr: r, w: 3, wr: weekReset)]
        let rough = try #require(UsageHistory.daysEstimate(one, currentWeekly: 3, now: one[1].date))
        #expect(DaysLabel.text(rough) == "Days left: estimating, needs a bit more use…")
        #expect(DaysLabel.help(rough).contains("So far: "))

        // Weekly hasn't moved yet: only a lower bound so far.
        let tiny = [point(0, d: 0, dr: r, w: 14, wr: weekReset), point(30, d: 3, dr: r, w: 14, wr: weekReset)]
        let bound = try #require(UsageHistory.daysEstimate(tiny, currentWeekly: 14, now: tiny[1].date))
        #expect(bound.perWeek.value == nil && bound.perWeek.high == nil)
        #expect(DaysLabel.help(bound).contains("So far: at least 3.2 of at least 3.7 full days left"))

        // Nothing used at all: nothing to say.
        let idle = [point(0, d: 5, dr: r, w: 14, wr: weekReset), point(30, d: 5, dr: r, w: 14, wr: weekReset)]
        #expect(UsageHistory.daysEstimate(idle, currentWeekly: 14, now: idle[1].date) == nil)
        #expect(DaysLabel.text(nil) == "Days left: learning from your usage…")
    }

    @Test func weeklyTicksSharpenTheEstimate() throws {
        // With observations minutes apart, the weekly percentage is seen stepping up at 3,
        // 10 and 17. Between the first and last step the week grew exactly 2 points while
        // the day grew 16.5 - 2.5 = 14.
        var points: [UsagePoint] = []
        for d in 0...19 {
            let w = 10 + (d >= 3 ? 1 : 0) + (d >= 10 ? 1 : 0) + (d >= 17 ? 1 : 0)
            points.append(point(Double(d), d: Double(d), dr: dailyReset, w: Double(w), wr: weekReset))
        }
        let chunk = try #require(UsageHistory.chunks(points, since: t0).first)
        #expect(chunk.daily == 14 && chunk.weekly == 2 && chunk.weeklyVariance == 0)
        let estimate = try #require(UsageHistory.daysEstimate(points, currentWeekly: 13, now: points[19].date))
        #expect(abs(try #require(estimate.perWeek.value) - 7) < 1e-9)
        // End to end (3 weekly points ± rounding) would be ±27%; the ticks give under ±10%.
        #expect(estimate.relativeError < 0.1)
        #expect(DaysLabel.text(estimate).hasPrefix("≈ 6.1 ± 0."))
    }

    @Test func coarseTicksFallBackToEndToEnd() throws {
        // Polled rarely: the steps are too wide to locate the ticks, so the totals win.
        let points = [point(0, d: 0, dr: dailyReset, w: 10, wr: weekReset),
                      point(30, d: 20, dr: dailyReset, w: 13, wr: weekReset),
                      point(120, d: 60, dr: dailyReset, w: 18, wr: weekReset)]
        let chunk = try #require(UsageHistory.chunks(points, since: t0).first)
        #expect(chunk.daily == 60 && chunk.weekly == 8)
    }

    /// One daily window `daysAgo` before t0, in which the day grew by `dd` and the week by `dw`.
    func day(daysAgo: Double, dd: Double, dw: Double) -> [UsagePoint] {
        let start = t0.addingTimeInterval(-daysAgo * 86400)
        let reset = start.addingTimeInterval(86400)
        return [UsagePoint(date: start, daily: 0, dailyResetsAt: reset, weekly: 20, weeklyResetsAt: reset.addingTimeInterval(86400)),
                UsagePoint(date: start.addingTimeInterval(12 * 3600), daily: dd, dailyResetsAt: reset,
                           weekly: 20 + dw, weeklyResetsAt: reset.addingTimeInterval(86400))]
    }

    @Test func recentDaysWeighMore() throws {
        let chunks = [UsageChunk(start: t0, end: t0, daily: 60, weekly: 12),
                      UsageChunk(start: t0, end: t0, daily: 60, weekly: 6)]
        let even = try #require(UsageHistory.fitCost(chunks, weights: [1, 1]))
        let recent = try #require(UsageHistory.fitCost(chunks, weights: [0.25, 1]))
        #expect(abs(even.cost - 0.15) < 1e-9)
        #expect(abs(recent.cost - (0.25 * 12 + 6) / (0.25 * 60 + 60)) < 1e-9)
    }

    @Test func limitChangeDropsOlderData() throws {
        // Two weeks at 12% of the week per full day, then the limits halve it to 6%.
        var points: [UsagePoint] = []
        for day in stride(from: 20.0, through: 8, by: -2) { points += self.day(daysAgo: day, dd: 60, dw: 7.2.rounded()) }
        for day in [5.0, 3, 1] { points += self.day(daysAgo: day, dd: 60, dw: 4) }
        let estimate = try #require(UsageHistory.daysEstimate(points, currentWeekly: 20, now: t0))
        #expect(estimate.days == 3)
        #expect(estimate.limitsChangedAt == t0.addingTimeInterval(-5 * 86400))
        #expect(abs(estimate.cost - 4.0 / 60) < 1e-9)
        #expect(DaysLabel.help(estimate).contains("seem to have changed"))
    }

    @Test func roundingNoiseIsNotALimitChange() throws {
        // Same limits; the weekly growth per day just rounds to 7 or 8.
        var points: [UsagePoint] = []
        for (i, day) in stride(from: 20.0, through: 1, by: -1.5).enumerated() {
            points += self.day(daysAgo: day, dd: 55 + Double(i % 3) * 5, dw: [7, 8, 8, 7, 9][i % 5])
        }
        let estimate = try #require(UsageHistory.daysEstimate(points, currentWeekly: 40, now: t0))
        #expect(estimate.limitsChangedAt == nil)
        #expect(estimate.days == 13)
        #expect(estimate.relativeError < 0.15)
    }

    @Test func weeklyResetBreaksThePair() {
        let a = point(0, d: 10, dr: dailyReset, w: 90, wr: t0.addingTimeInterval(60))
        let b = point(5, d: 20, dr: dailyReset, w: 2, wr: weekReset)
        #expect(UsageHistory.growth(.daily, from: a, to: b) == 10)
        #expect(UsageHistory.growth(.weekly, from: a, to: b) == nil)
    }
}

@Suite struct UsageChartModelTests {
    let end = Date(timeIntervalSince1970: 1_790_018_000)
    /// The 24-hour window the daily chart draws ends at the reset.
    var windowStart: Date { end.addingTimeInterval(-86400) }
    /// Anchor close to the reset, where the test data lives.
    var start: Date { end.addingTimeInterval(-5 * 3600) }

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    func points(_ values: [(Double, Double)]) -> [UsagePoint] {
        values.map { UsagePoint(date: at($0.0), daily: $0.1, dailyResetsAt: end, weekly: 50,
                                weeklyResetsAt: end.addingTimeInterval(86400)) }
    }

    @Test func samplesStayInTheWindow() {
        var history = points([(10, 5), (20, 8)])
        // From a different reset: left out.
        history.insert(UsagePoint(date: at(-30), daily: 90, dailyResetsAt: start, weekly: 40, weeklyResetsAt: nil), at: 0)
        history.append(UsagePoint(date: at(25), daily: 3, dailyResetsAt: end.addingTimeInterval(86400), weekly: 50, weeklyResetsAt: nil))
        let model = UsageChartModel.make(points: history, metric: .daily, resetsAt: end, now: at(30))!
        #expect(model.samples.map(\.value) == [0, 5, 8, 8])
        #expect(model.samples.first?.date == windowStart)
        #expect(model.samples.last?.date == at(30))
        #expect(UsageChartModel.make(points: history, metric: .daily, resetsAt: at(-1), now: at(30)) == nil)
        #expect(UsageChartModel.make(points: history, metric: .daily, resetsAt: nil, now: at(30)) == nil)
    }

    @Test func unwatchedStretchesSplitTheLine() {
        let samples = [(0.0, 0.0), (5, 4), (10, 6), (120, 30), (125, 32)].map {
            UsageSample(date: at($0.0), value: $0.1)
        }
        let lines = UsageChartModel.lines(samples)
        #expect(lines.map(\.watched) == [true, false, true])
        #expect(lines.map(\.samples.count) == [3, 2, 2])
    }

    @Test func trendsPerStretchOfUse() throws {
        // 12%/h for 30 min, an idle half hour (heartbeats), then 30%/h for 20 min.
        let model = UsageChartModel.make(points: points([(0, 0), (10, 2), (20, 4), (30, 6), (40, 6), (50, 6), (60, 6),
                                                         (70, 11), (80, 16)]),
                                         metric: .daily, resetsAt: end, now: at(82))!
        #expect(model.trends.count == 2)
        let first = try #require(model.trends.first), second = try #require(model.trends.last)
        #expect(abs(first.perHour - 12) < 1e-6)
        #expect(first.start.date == at(0) && first.end.date == at(30))
        #expect(abs(second.perHour - 30) < 1e-6)
        #expect(second.start.date == at(60))

        // Still going: 16% + 30%/h hits 100% after 2h 48m, before the reset 3h 38m away.
        let projection = try #require(model.projection)
        #expect(projection.hitsLimit)
        #expect(abs(projection.to.date.timeIntervalSince(at(82 + 168))) < 1)
        #expect(UsageChart.caption(model, time: { _ in "T" }) == "At 30%/h you'd hit the limit at T")
    }

    @Test func projectionStopsAtResetAndWhenIdle() throws {
        let slow = UsageChartModel.make(points: points([(200, 0), (210, 1), (220, 2), (230, 3)]),
                                        metric: .daily, resetsAt: end, now: at(230))!
        let projection = try #require(slow.projection)
        #expect(!projection.hitsLimit)
        #expect(projection.to.date == end)
        #expect(abs(projection.to.value - (3 + 6 * 70.0 / 60)) < 1e-6)
        #expect(UsageChart.caption(slow) == "At 6.0%/h: ≈ 10% by the reset")

        let idle = UsageChartModel.make(points: points([(200, 0), (210, 1), (220, 2), (230, 3)]),
                                        metric: .daily, resetsAt: end, now: at(260))!
        #expect(idle.projection == nil)
        #expect(UsageChart.caption(idle) == "Last active stretch: 6.0%/h")
    }

    @Test func noTrendFromASingleStep() {
        // First seen long after the window started: the rise before that wasn't watched.
        let model = UsageChartModel.make(points: points([(100, 1), (102, 2)]), metric: .daily, resetsAt: end, now: at(103))!
        #expect(model.trends.isEmpty)
        #expect(UsageChart.caption(model) == nil)
    }

    @Test func hourMarksKeepTheStrideAndAvoidEdges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_790_000_000 - 1_790_000_000.truncatingRemainder(dividingBy: 3600) + 50 * 60)
        // Window 14:50 → next day 14:50 UTC, stride 6: 18:00, 00:00, 06:00, 12:00.
        let marks = UsageChart.hourMarks(in: DateInterval(start: start, duration: 86400), calendar: calendar)
        #expect(marks.count == 4)
        #expect(marks.first == start.addingTimeInterval(3 * 3600 + 10 * 60))
        #expect(marks.allSatisfy { calendar.component(.hour, from: $0) % 6 == 0 })
    }

    @Test func hoverValueInterpolates() {
        let model = UsageChartModel.make(points: points([(10, 10), (20, 20)]), metric: .daily, resetsAt: end, now: at(30))!
        #expect(model.value(at: at(15)) == 15)
        #expect(model.value(at: at(25)) == 20)
        #expect(model.value(at: at(31)) == nil)
    }

    @Test func weeklyCaptionComparesWithElapsedTime() {
        let weekEnd = start.addingTimeInterval(7 * 86400)
        let history = [UsagePoint(date: start.addingTimeInterval(3600), daily: 5, dailyResetsAt: nil,
                                  weekly: 30, weeklyResetsAt: weekEnd)]
        let model = UsageChartModel.make(points: history, metric: .weekly, resetsAt: weekEnd,
                                         now: start.addingTimeInterval(3.5 * 86400))!
        #expect(UsageChart.caption(model) == "30% used · 50% of the week has passed")
        #expect(model.projection == nil)
    }
}
