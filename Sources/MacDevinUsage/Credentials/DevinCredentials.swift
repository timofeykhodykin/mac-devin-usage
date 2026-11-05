import Foundation
import SQLite3

enum AuthError: Error, LocalizedError {
    case notSignedIn
    /// The API key was rejected — only a new sign-in to Devin can fix this.
    case signInExpired

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Devin. Open Devin (or run `devin auth login`) and sign in."
        case .signInExpired:
            return "Devin sign-in expired. Open Devin and sign in again."
        }
    }
}

/// The Devin API key and the API server it belongs to.
struct DevinCredentials: Equatable {
    var apiKey: String
    var apiServerURL: URL

    /// Where requests go when no other API server is named by the sign-in.
    static let defaultAPIServer = URL(string: "https://server.codeium.com")!

    // MARK: - Devin Desktop

    /// Devin Desktop's VS Code-style state database.
    static var desktopDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
    }

    /// The sign-in Devin Desktop saved, or nil. The `windsurfAuthStatus` row holds ~1 MB
    /// of JSON, so the two fields we need are extracted inside SQLite and the value is
    /// never loaded whole. Opened read-only with a short busy timeout, because Desktop
    /// can hold the database locked while it runs.
    static func readDesktop(database url: URL = desktopDatabaseURL) -> DevinCredentials? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        let sql = """
        SELECT json_extract(CAST(value AS TEXT),'$.apiKey'), \
               json_extract(CAST(value AS TEXT),'$.apiServerUrl') \
        FROM ItemTable WHERE key='windsurfAuthStatus'
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let keyPointer = sqlite3_column_text(statement, 0) else { return nil }
        let apiKey = String(cString: keyPointer)
        guard !apiKey.isEmpty else { return nil }
        let server = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        return DevinCredentials(apiKey: apiKey, apiServerURL: apiServerURL(server))
    }

    // MARK: - Devin CLI

    static var cliCredentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devin/credentials.toml")
    }

    /// The sign-in the Devin CLI saved, or nil.
    static func readCLI(file url: URL = cliCredentialsURL) -> DevinCredentials? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseCLI(text)
    }

    /// Loose TOML: the first `windsurf_api_key` or `api_key` assignment, plus
    /// `api_server_url`; section headers, comments and everything else are ignored.
    static func parseCLI(_ text: String) -> DevinCredentials? {
        var apiKey: String?
        var server: String?
        for line in text.split(separator: "\n") {
            guard let (name, value) = assignment(line) else { continue }
            if apiKey == nil, name == "windsurf_api_key" || name == "api_key" { apiKey = value }
            if server == nil, name == "api_server_url" { server = value }
        }
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return DevinCredentials(apiKey: apiKey, apiServerURL: apiServerURL(server))
    }

    /// `key = "value"` (or `'value'`), or nil for comments, sections and non-assignments.
    private static func assignment(_ line: Substring) -> (name: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["),
              let eq = trimmed.firstIndex(of: "=") else { return nil }
        let name = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            value.removeFirst()
            guard let end = value.firstIndex(of: quote) else { return nil }
            return (name, String(value[..<end]))
        }
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        return (name, value.trimmingCharacters(in: .whitespaces))
    }

    /// Only an https URL is trusted; anything else falls back to the default server.
    static func apiServerURL(_ raw: String?) -> URL {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil else {
            return defaultAPIServer
        }
        return url
    }
}

/// Supplies the Devin API key, read straight from where Devin keeps it on every call:
/// nothing is cached, so a fresh sign-in or a rotated key is picked up at once. Strictly
/// read-only — it never writes to Devin's files, and the key is never logged.
actor DevinSignIn {
    private let databaseURL: URL
    private let cliURL: URL

    init(databaseURL: URL = DevinCredentials.desktopDatabaseURL,
         cliURL: URL = DevinCredentials.cliCredentialsURL) {
        self.databaseURL = databaseURL
        self.cliURL = cliURL
    }

    /// The current credentials: Devin Desktop first, then the Devin CLI.
    func credentials() throws -> DevinCredentials {
        if let credentials = DevinCredentials.readDesktop(database: databaseURL)
            ?? DevinCredentials.readCLI(file: cliURL) {
            return credentials
        }
        throw AuthError.notSignedIn
    }

    /// Called after the API rejected `key` with 401: re-reads in case Devin signed in
    /// again or the other source holds a newer key.
    func recover(fromRejected key: String) throws -> DevinCredentials {
        let candidates = [DevinCredentials.readDesktop(database: databaseURL),
                          DevinCredentials.readCLI(file: cliURL)].compactMap { $0 }
        guard !candidates.isEmpty else { throw AuthError.notSignedIn }
        guard let credentials = candidates.first(where: { $0.apiKey != key }) else { throw AuthError.signInExpired }
        Log.auth.info("401 recovered: another Devin API key is stored")
        return credentials
    }
}
