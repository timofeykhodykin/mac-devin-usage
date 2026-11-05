import AppKit
import Foundation

/// Fetches usage from Devin's `GetUserStatus` endpoint on the refresh interval. Its rate
/// limits aren't documented, so it is called as rarely as the freshness of the displayed
/// data allows, with exponential backoff on HTTP 429.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: UsageError?
    @Published private(set) var plan: String?
    /// While rate limited, automatic API polling pauses until this time.
    @Published private(set) var backoffUntil: Date?
    /// True when we have no data, or the last attempt failed and the data has gone stale.
    /// The menu bar then shows `?`; the dropdown keeps showing the last numbers.
    @Published private(set) var isUnavailable = false
    /// Every change of either percentage (plus heartbeats), for the chart and the days estimate.
    @Published private(set) var history: [UsagePoint] = []

    private let api: UsageAPI
    private let signIn: DevinSignIn
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    private var availabilityTimer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var consecutiveRateLimits = 0
    private var lastAPIAttempt: Date?
    /// Even manual refreshes don't hit a rate-limited API more often than this.
    private static let minManualSpacing: TimeInterval = 60
    private static let maxBackoff: TimeInterval = 30 * 60

    init(signIn: DevinSignIn = DevinSignIn(), defaults: UserDefaults = .standard) {
        self.signIn = signIn
        self.api = UsageAPI(signIn: signIn)
        self.defaults = defaults
        if let data = defaults.data(forKey: SettingsKey.cachedSnapshot) {
            snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        }
        plan = snapshot?.plan
        history = UsageHistory.load()
        watchAvailability()
        observeWake()
        restartPolling()
    }

    /// A static store for previews and screenshots: no polling, no credentials, no settings changes.
    init(previewSnapshot: UsageSnapshot, plan: String?, history: [UsagePoint] = []) {
        self.signIn = DevinSignIn()
        self.api = UsageAPI(signIn: signIn)
        self.defaults = UserDefaults(suiteName: "dev.mac-devin-usage.preview") ?? .standard
        self.snapshot = previewSnapshot
        self.plan = plan
        self.history = history
    }

    /// Recomputes `isUnavailable`. Staleness depends on the clock, so this also runs on a timer.
    private func updateAvailability() {
        let backingOff = backoffUntil.map { $0 > Date() } ?? false
        let unavailable = snapshot == nil || ((lastError != nil || backingOff) && !isDataFresh)
        if unavailable != isUnavailable { isUnavailable = unavailable }
    }

    var refreshInterval: TimeInterval {
        let stored = defaults.integer(forKey: SettingsKey.refreshInterval)
        return TimeInterval(RefreshInterval(rawValue: stored)?.rawValue ?? RefreshInterval.standard.rawValue)
    }

    /// How old the displayed data is.
    var dataAge: TimeInterval {
        snapshot.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
    }

    /// True when the displayed data is recent enough that a rate limit doesn't matter.
    var isDataFresh: Bool { dataAge < refreshInterval * 1.5 }

    /// Restarts the polling loop (e.g. after the interval setting changed).
    func restartPolling() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.dataAge >= self.refreshInterval * 0.9 {
                    await self.refresh()
                }
                try? await Task.sleep(for: .seconds(self.nextDelay()))
            }
        }
    }

    /// Manual refresh from the UI. Asks the API unless we are rate limited and already
    /// asked within the last minute (hammering only extends it).
    func refreshNow() {
        Task { await refresh(manual: true) }
    }

    // MARK: - API

    private func refresh(manual: Bool = false) async {
        guard !isRefreshing else { return }
        if let backoffUntil, backoffUntil > Date() {
            guard manual else { return }
            if let last = lastAPIAttempt, Date().timeIntervalSince(last) < Self.minManualSpacing {
                Log.usage.info("Manual refresh skipped: rate limited, last API call was under a minute ago")
                return
            }
        }
        lastAPIAttempt = Date()
        isRefreshing = true
        defer {
            isRefreshing = false
            updateAvailability()
        }

        do {
            let fresh = try await api.fetch()
            adopt(fresh)
            lastError = nil
            backoffUntil = nil
            consecutiveRateLimits = 0
            plan = snapshot?.plan
            Log.usage.info("Fetched usage: daily \(fresh.daily?.utilization ?? -1, privacy: .public)%, weekly \(fresh.weekly?.utilization ?? -1, privacy: .public)%")
        } catch let error as UsageError {
            Log.usage.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
            lastError = error
            if case .rateLimited(let retryAfter) = error {
                // Exponential backoff (2×, 4×, 8× the interval…), never shorter than the
                // server's Retry-After, capped at 30 minutes.
                // Manual clicks don't escalate the backoff; only the automatic schedule does.
                if !manual || consecutiveRateLimits == 0 { consecutiveRateLimits += 1 }
                let exponential = refreshInterval * pow(2, Double(consecutiveRateLimits))
                let delay = min(Self.maxBackoff, max(retryAfter ?? 0, exponential, 60))
                backoffUntil = Date().addingTimeInterval(delay)
                Log.usage.info("Rate limited \(self.consecutiveRateLimits, privacy: .public)× in a row; pausing \(Int(delay), privacy: .public)s")
            }
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    private func nextDelay() -> TimeInterval {
        if let backoffUntil, backoffUntil > Date() {
            return min(backoffUntil.timeIntervalSinceNow + 1, refreshInterval)
        }
        if let lastError {
            switch lastError {
            case .network, .http, .decoding:
                // Transient: retry sooner than the normal interval.
                return min(refreshInterval, 30)
            case .auth, .noQuota:
                // Only a new sign-in or another plan fixes these; with short intervals the
                // stale data would otherwise make every pass retry right away.
                return max(refreshInterval, 60)
            case .rateLimited:
                break
            }
        }
        // Wake up when the current data becomes due, not a full interval from now.
        return max(5, refreshInterval - dataAge)
    }

    // MARK: - Availability

    /// `isUnavailable` goes false → true the moment the data becomes stale, not on the next
    /// fetch, so it is recomputed on a timer.
    private func watchAvailability() {
        availabilityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAvailability() }
        }
    }

    /// Takes a newer snapshot, keeping windows the new source didn't report.
    private func adopt(_ incoming: UsageSnapshot) {
        var merged = incoming
        if merged.daily == nil { merged.daily = snapshot?.daily }
        if merged.weekly == nil { merged.weekly = snapshot?.weekly }
        if merged.plan == nil { merged.plan = snapshot?.plan }
        snapshot = merged
        if let data = try? JSONEncoder().encode(merged) {
            defaults.set(data, forKey: SettingsKey.cachedSnapshot)
        }
        record(merged)
    }

    /// Appends to the usage history when something changed (or as a heartbeat).
    private func record(_ snapshot: UsageSnapshot) {
        let point = UsagePoint(snapshot)
        if let last = history.last, last.date > point.date.addingTimeInterval(3600) {
            // The clock jumped back: entries "from the future" would block recording.
            history = UsageHistory.pruned(history, now: point.date)
            UsageHistory.rewrite(history)
        }
        guard UsageHistory.shouldRecord(point, after: history.last) else { return }
        history.append(point)
        UsageHistory.append(point)
        // The app can run for weeks; drop old entries a day's worth at a time.
        if let first = history.first, point.date.timeIntervalSince(first.date) > UsageHistory.retention + 86400 {
            history = UsageHistory.pruned(history, now: point.date)
            UsageHistory.rewrite(history)
        }
    }

    /// Full daily limits per weekly limit and how many are left, once there's enough history.
    var daysEstimate: DaysEstimate? {
        UsageHistory.daysEstimate(history, currentWeekly: snapshot?.weekly?.currentUtilization())
    }

    /// After sleep the data is usually stale; refresh right away (with a short delay for
    /// the network to come back).
    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.restartPolling()
                }
            }
            wakeObservers.append(observer)
        }
    }
}
