import XCTest
@testable import CrateDiggerCore

/// In-memory SecretStoring so tests never touch the real keychain
/// (SecItem calls can prompt or fail in headless runners).
private final class FakeSecretStore: SecretStoring {
    var storage: [String: String] = [:]

    func get(_ key: String) -> String? { storage[key] }

    func set(_ key: String, _ value: String?) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}

final class KeychainStoreTests: XCTestCase {

    private let suiteName = "KeychainStoreTests"
    private let subsonicKey = "cratedigger.remote.subsonicPassword"
    private let lastFmKey = "cratedigger.lastfm.sessionKey"

    private var defaults: UserDefaults!
    private var secrets: FakeSecretStore!
    private var prefs: PreferencesStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        secrets = FakeSecretStore()
        prefs = PreferencesStore(defaults: defaults, secrets: secrets)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        secrets = nil
        prefs = nil
        super.tearDown()
    }

    // MARK: - Get / set / delete

    func testSetAndGetRoundTrip() {
        prefs.subsonicPassword = "hunter2"
        XCTAssertEqual(prefs.subsonicPassword, "hunter2")
        XCTAssertEqual(secrets.storage[subsonicKey], "hunter2")

        prefs.lastFmSessionKey = "session-abc"
        XCTAssertEqual(prefs.lastFmSessionKey, "session-abc")
        XCTAssertEqual(secrets.storage[lastFmKey], "session-abc")
    }

    func testGetReturnsNilWhenUnset() {
        XCTAssertNil(prefs.subsonicPassword)
        XCTAssertNil(prefs.lastFmSessionKey)
    }

    func testSetNilDeletes() {
        prefs.subsonicPassword = "hunter2"
        prefs.subsonicPassword = nil
        XCTAssertNil(prefs.subsonicPassword)
        XCTAssertNil(secrets.storage[subsonicKey])
    }

    func testSetNeverWritesPlaintextToDefaults() {
        prefs.subsonicPassword = "hunter2"
        prefs.lastFmSessionKey = "session-abc"
        XCTAssertNil(defaults.string(forKey: subsonicKey))
        XCTAssertNil(defaults.string(forKey: lastFmKey))
    }

    // MARK: - Legacy plaintext migration

    func testReadMigratesLegacyPlaintextIntoKeychainAndRemovesFromDefaults() {
        defaults.set("legacy-password", forKey: subsonicKey)

        XCTAssertEqual(prefs.subsonicPassword, "legacy-password")
        XCTAssertEqual(secrets.storage[subsonicKey], "legacy-password")
        XCTAssertNil(defaults.object(forKey: subsonicKey))
    }

    func testReadMigratesLegacyLastFmSessionKey() {
        defaults.set("legacy-session", forKey: lastFmKey)

        XCTAssertEqual(prefs.lastFmSessionKey, "legacy-session")
        XCTAssertEqual(secrets.storage[lastFmKey], "legacy-session")
        XCTAssertNil(defaults.object(forKey: lastFmKey))
    }

    func testMigrationDoesNotOverwriteExistingKeychainValue() {
        secrets.storage[subsonicKey] = "keychain-wins"
        defaults.set("stale-plaintext", forKey: subsonicKey)

        XCTAssertEqual(prefs.subsonicPassword, "keychain-wins")
        XCTAssertNil(defaults.object(forKey: subsonicKey))
    }

    func testWriteRemovesLegacyPlaintextFromDefaults() {
        defaults.set("legacy-password", forKey: subsonicKey)

        prefs.subsonicPassword = "new-password"

        XCTAssertEqual(prefs.subsonicPassword, "new-password")
        XCTAssertNil(defaults.object(forKey: subsonicKey))
    }

    func testWriteNilRemovesLegacyPlaintextFromDefaults() {
        defaults.set("legacy-password", forKey: subsonicKey)

        prefs.subsonicPassword = nil

        XCTAssertNil(prefs.subsonicPassword)
        XCTAssertNil(defaults.object(forKey: subsonicKey))
    }
}
