import Foundation

/// Last.fm application credentials (API key + shared secret).
///
/// These are *application* credentials, not the user's account credentials.
/// They are intentionally **not** stored in source control. A release build
/// embeds them via `scripts/package-app.sh` (which injects them into the app
/// bundle's `Info.plist`); a `swift run` dev build can supply them through
/// environment variables. When neither source provides them, Last.fm features
/// degrade gracefully to a no-op (see `LastFMScrobbler.isConfigured`).
struct LastFMCredentials: Sendable, Equatable {
    let apiKey: String
    let apiSecret: String
}

/// Resolves `LastFMCredentials` from the runtime environment.
///
/// Precedence (first non-empty wins), per field:
///   1. Environment variable — `CRATEDIGGER_LASTFM_API_KEY` / `..._SECRET`
///   2. App bundle `Info.plist` — `LastFMAPIKey` / `LastFMAPISecret`
///   3. Otherwise `nil` (Last.fm disabled).
enum LastFMCredentialsResolver {
    static let apiKeyEnvName = "CRATEDIGGER_LASTFM_API_KEY"
    static let apiSecretEnvName = "CRATEDIGGER_LASTFM_API_SECRET"
    static let apiKeyPlistName = "LastFMAPIKey"
    static let apiSecretPlistName = "LastFMAPISecret"

    /// Pure resolver — injectable sources make this unit-testable without
    /// touching `ProcessInfo`/`Bundle`.
    static func resolve(
        environment: [String: String],
        infoPlistValue: (String) -> String?
    ) -> LastFMCredentials? {
        func value(env envName: String, plist plistName: String) -> String? {
            if let v = environment[envName], !v.isEmpty { return v }
            if let v = infoPlistValue(plistName), !v.isEmpty { return v }
            return nil
        }

        guard let key = value(env: apiKeyEnvName, plist: apiKeyPlistName),
              let secret = value(env: apiSecretEnvName, plist: apiSecretPlistName) else {
            return nil
        }
        return LastFMCredentials(apiKey: key, apiSecret: secret)
    }

    /// Resolves from the real process environment and main bundle.
    static func resolveDefault() -> LastFMCredentials? {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            infoPlistValue: { Bundle.main.object(forInfoDictionaryKey: $0) as? String }
        )
    }
}
