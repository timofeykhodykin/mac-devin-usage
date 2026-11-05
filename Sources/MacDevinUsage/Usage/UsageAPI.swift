import Foundation

struct UsageWindow: Codable, Equatable {
    /// 0…100
    var utilization: Double
    var resetsAt: Date?

    /// Once the reset time has passed, the window starts over at 0 — true even if we
    /// couldn't fetch anything since.
    func hasReset(now: Date = Date()) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    func currentUtilization(now: Date = Date()) -> Double {
        hasReset(now: now) ? 0 : utilization
    }
}

enum UsageSource: String, Codable {
    /// Polled `GetUserStatus`.
    case api
}

struct UsageSnapshot: Codable, Equatable {
    var daily: UsageWindow?
    var weekly: UsageWindow?
    var fetchedAt: Date
    var source: UsageSource? = .api
    var plan: String? = nil
}

enum UsageError: Error, LocalizedError {
    case auth(AuthError)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case decoding
    /// The plan bills per credit instead: there is no daily or weekly quota to show.
    case noQuota

    var errorDescription: String? {
        switch self {
        case .auth(let error): return error.localizedDescription
        case .rateLimited: return "Rate limited by Devin; backing off."
        case .http(let code): return "Usage request failed (HTTP \(code))."
        case .network(let message): return "Network error: \(message)"
        case .decoding: return "Unexpected response from the usage endpoint."
        case .noQuota: return "This Devin plan has no daily or weekly quota."
        }
    }

    /// Errors that need the user to act (sign in again), as opposed to transient ones.
    var needsUserAction: Bool {
        if case .auth(let error) = self {
            switch error {
            case .notSignedIn, .signInExpired: return true
            }
        }
        return false
    }
}

/// `POST {apiServerUrl}/exa.seat_management_pb.SeatManagementService/GetUserStatus` — the
/// Connect-RPC call Devin's own integrations use for the account's plan status.
struct UsageAPI {
    /// The request is rejected without an IDE name; this app reports itself as one.
    static let ideName = "mac-devin-usage"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    let signIn: DevinSignIn
    var session: URLSession = .shared

    func fetch() async throws -> UsageSnapshot {
        let credentials: DevinCredentials
        do {
            credentials = try await signIn.credentials()
        } catch let error as AuthError {
            throw UsageError.auth(error)
        }

        let (status, data, response) = try await post(credentials: credentials)
        switch status {
        case 200:
            return try Self.parse(data)
        case 401:
            // The stored key was rejected — re-read once in case a newer sign-in exists.
            let fresh: DevinCredentials
            do {
                fresh = try await signIn.recover(fromRejected: credentials.apiKey)
            } catch let error as AuthError {
                throw UsageError.auth(error)
            }
            let (retryStatus, retryData, retryResponse) = try await post(credentials: fresh)
            if retryStatus == 200 { return try Self.parse(retryData) }
            throw Self.error(for: retryStatus, response: retryResponse, body: retryData)
        default:
            throw Self.error(for: status, response: response, body: data)
        }
    }

    private func post(credentials: DevinCredentials) async throws -> (Int, Data, HTTPURLResponse?) {
        var request = URLRequest(url: Self.endpoint(for: credentials.apiServerURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "apiKey": credentials.apiKey,
                "ideName": Self.ideName,
                "ideVersion": Self.appVersion,
                "extensionVersion": Self.appVersion,
                "locale": "en"
            ]
        ])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return (http?.statusCode ?? 0, data, http)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
    }

    static func endpoint(for apiServerURL: URL) -> URL {
        apiServerURL.appendingPathComponent("exa.seat_management_pb.SeatManagementService/GetUserStatus")
    }

    private static func error(for status: Int, response: HTTPURLResponse?, body: Data) -> UsageError {
        if status != 200 {
            let text = String(data: body.prefix(400), encoding: .utf8) ?? ""
            let headers = (response?.allHeaderFields ?? [:])
                .compactMap { key, value -> String? in
                    let name = "\(key)".lowercased()
                    guard name.hasPrefix("retry") || name.contains("ratelimit") || name == "request-id" else { return nil }
                    return "\(name)=\(value)"
                }
                .sorted().joined(separator: " ")
            Log.usage.error("HTTP \(status, privacy: .public) body: \(text, privacy: .public) headers: \(headers, privacy: .public)")
        }
        switch status {
        case 429:
            let header = response?.value(forHTTPHeaderField: "Retry-After")
            Log.usage.info("429 Retry-After: \(header ?? "none", privacy: .public)")
            return .rateLimited(retryAfter: parseRetryAfter(header))
        case 401:
            return .auth(.signInExpired)
        default:
            return .http(status)
        }
    }

    // MARK: - Parsing

    /// `Retry-After` is either delta-seconds or an HTTP date.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// proto3 JSON: int64s arrive as strings, so either form is accepted.
    private struct Int64Value: Decodable {
        let value: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int64.self) {
                value = int
            } else if let string = try? container.decode(String.self), let int = Int64(string) {
                value = int
            } else {
                throw DecodingError.typeMismatch(Int64.self, .init(
                    codingPath: decoder.codingPath, debugDescription: "expected an int64 or its string form"))
            }
        }
    }

    private struct Response: Decodable {
        struct UserStatus: Decodable {
            struct PlanStatus: Decodable {
                struct PlanInfo: Decodable {
                    let planName: String?
                    let hideDailyQuota: Bool?
                    let hideWeeklyQuota: Bool?
                }
                let planInfo: PlanInfo?
                let dailyQuotaRemainingPercent: Int64Value?
                let weeklyQuotaRemainingPercent: Int64Value?
                let dailyQuotaResetAtUnix: Int64Value?
                let weeklyQuotaResetAtUnix: Int64Value?
            }
            let planStatus: PlanStatus?
        }
        let userStatus: UserStatus
    }

    /// The API reports *remaining* percentages, and proto3 omits zero values: a window
    /// exists when its percent or its reset time is present, and a missing percent means
    /// 0 remaining — 100% used.
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw UsageError.decoding
        }
        let status = response.userStatus.planStatus
        func window(remaining: Int64Value?, reset: Int64Value?, hidden: Bool?) -> UsageWindow? {
            guard hidden != true, remaining != nil || reset != nil else { return nil }
            return UsageWindow(
                utilization: min(100, max(0, 100 - Double(remaining?.value ?? 0))),
                resetsAt: reset.map { Date(timeIntervalSince1970: TimeInterval($0.value)) })
        }
        let snapshot = UsageSnapshot(
            daily: window(remaining: status?.dailyQuotaRemainingPercent,
                          reset: status?.dailyQuotaResetAtUnix,
                          hidden: status?.planInfo?.hideDailyQuota),
            weekly: window(remaining: status?.weeklyQuotaRemainingPercent,
                           reset: status?.weeklyQuotaResetAtUnix,
                           hidden: status?.planInfo?.hideWeeklyQuota),
            fetchedAt: now, source: .api,
            plan: status?.planInfo?.planName)
        // Credit/ACU-billed plans report neither quota.
        guard snapshot.daily != nil || snapshot.weekly != nil else { throw UsageError.noQuota }
        return snapshot
    }
}
