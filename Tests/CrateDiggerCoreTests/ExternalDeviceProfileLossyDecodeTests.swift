import XCTest
@testable import CrateDiggerCore

final class ExternalDeviceProfileLossyDecodeTests: XCTestCase {
    private let key = "cratedigger.externalDevices.profiles"

    private func makeStore() -> (PreferencesStore, UserDefaults) {
        let defaults = makeScratchDefaults()
        return (PreferencesStore(defaults: defaults), defaults)
    }

    private func profile(_ name: String) -> ExternalDeviceProfile {
        ExternalDeviceProfile(name: name)
    }

    /// A valid profile's JSON with its kind swapped for one this build does not know.
    private func futureElement(name: String = "Future") throws -> [String: Any] {
        let data = try JSONEncoder().encode(profile(name))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["kind"] = "stock_ipod"
        return object
    }

    private func store(_ elements: [Any], in defaults: UserDefaults) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: elements), forKey: key)
    }

    private func encoded(_ p: ExternalDeviceProfile) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(p))
    }

    private func storedElements(_ defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try XCTUnwrap(defaults.data(forKey: key))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testGetterSkipsUnknownKindAndReturnsTheRest() throws {
        let (prefs, defaults) = makeStore()
        let a = profile("A"), b = profile("B")
        try store([try encoded(a), try futureElement(), try encoded(b)], in: defaults)
        XCTAssertEqual(Set(prefs.savedExternalDeviceProfiles.map(\.id)), [a.id, b.id])
    }

    func testUpsertKeepsUnknownElement() throws {
        let (prefs, defaults) = makeStore()
        try store([try encoded(profile("A")), try futureElement(), try encoded(profile("B"))], in: defaults)
        prefs.upsertExternalDeviceProfile(profile("C"))
        let elements = try storedElements(defaults)
        XCTAssertEqual(elements.count, 4)
        XCTAssertEqual(elements.filter { $0["kind"] as? String == "stock_ipod" }.count, 1)
        XCTAssertEqual(prefs.savedExternalDeviceProfiles.count, 3)
    }

    func testRemoveKeepsUnknownElement() throws {
        let (prefs, defaults) = makeStore()
        let a = profile("A")
        try store([try encoded(a), try futureElement(), try encoded(profile("B"))], in: defaults)
        prefs.removeExternalDeviceProfile(id: a.id)
        let elements = try storedElements(defaults)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.filter { $0["kind"] as? String == "stock_ipod" }.count, 1)
        XCTAssertEqual(prefs.savedExternalDeviceProfiles.count, 1)
    }

    func testRemovingEveryValidProfileStillKeepsUnknownElement() throws {
        let (prefs, defaults) = makeStore()
        let a = profile("A")
        try store([try encoded(a), try futureElement()], in: defaults)
        prefs.removeExternalDeviceProfile(id: a.id)
        XCTAssertEqual(try storedElements(defaults).count, 1)
    }

    func testAllValidDataRoundTrips() throws {
        let (prefs, defaults) = makeStore()
        let a = profile("A"), b = profile("B")
        prefs.savedExternalDeviceProfiles = [a, b]
        XCTAssertEqual(prefs.savedExternalDeviceProfiles, [a, b])
        // Key order of a default encoder is not stable, so compare what a
        // reader sees: the same array of the same two profiles.
        let stored = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertEqual(try JSONDecoder().decode([ExternalDeviceProfile].self, from: stored), [a, b])
        prefs.savedExternalDeviceProfiles = prefs.savedExternalDeviceProfiles
        let again = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertEqual(try JSONDecoder().decode([ExternalDeviceProfile].self, from: again), [a, b])
    }

    func testAbsentAndEmptyKeyBehaveAsBefore() {
        let (prefs, defaults) = makeStore()
        XCTAssertEqual(prefs.savedExternalDeviceProfiles, [])
        prefs.savedExternalDeviceProfiles = []
        XCTAssertNil(defaults.data(forKey: key))
        defaults.set(Data("[]".utf8), forKey: key)
        XCTAssertEqual(prefs.savedExternalDeviceProfiles, [])
    }

    func testCorruptBlobReadsEmptyIsNotOverwrittenByReadAndReplacedByWrite() {
        let (prefs, defaults) = makeStore()
        let junk = Data("not json".utf8)
        defaults.set(junk, forKey: key)
        XCTAssertEqual(prefs.savedExternalDeviceProfiles, [])
        XCTAssertEqual(defaults.data(forKey: key), junk)
        prefs.upsertExternalDeviceProfile(profile("A"))
        XCTAssertEqual(prefs.savedExternalDeviceProfiles.count, 1)
    }
}
