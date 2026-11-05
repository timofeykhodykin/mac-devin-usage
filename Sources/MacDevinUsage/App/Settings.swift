import Foundation

enum MenuIcon: String, CaseIterable, Identifiable {
    case devin
    case sparkle
    case sparkles
    case brain
    case bolt
    case gauge
    case flame
    case terminal
    case chart
    case none

    var id: String { rawValue }

    /// SF Symbol name, or nil for the custom-drawn Devin mark / no icon.
    var symbolName: String? {
        switch self {
        case .devin, .none: return nil
        case .sparkle: return "sparkle"
        case .sparkles: return "sparkles"
        case .brain: return "brain"
        case .bolt: return "bolt"
        case .gauge: return "gauge.with.dots.needle.67percent"
        case .flame: return "flame"
        case .terminal: return "apple.terminal"
        case .chart: return "chart.bar"
        }
    }

    var title: String {
        switch self {
        case .devin: return "Devin"
        case .none: return "None"
        default: return rawValue.capitalized
        }
    }
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    var id: Int { rawValue }

    static let standard = RefreshInterval.thirtySeconds

    var title: String {
        if rawValue < 60 { return "\(rawValue) seconds" }
        let minutes = rawValue / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

enum SettingsKey {
    static let icon = "menuIcon"
    static let refreshInterval = "refreshInterval"
    static let cachedSnapshot = "cachedSnapshot"
    static let showWeekly = "showWeeklyInMenuBar"
    static let showChart = "showUsageChart"
    static let chartMetric = "usageChartMetric"
}
