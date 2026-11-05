import os

/// View with: `log stream --predicate 'subsystem == "dev.mac-devin-usage"' --info`
/// Never log API keys — only outcomes.
enum Log {
    static let auth = Logger(subsystem: "dev.mac-devin-usage", category: "auth")
    static let usage = Logger(subsystem: "dev.mac-devin-usage", category: "usage")
}
