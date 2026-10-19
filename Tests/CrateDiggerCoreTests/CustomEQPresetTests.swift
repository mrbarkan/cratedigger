import XCTest
@testable import CrateDiggerCore

final class CustomEQPresetTests: XCTestCase {

    func testEmptySlotsFillOneRowOfSix() {
        let slots = CustomEQPreset.emptySlots
        XCTAssertEqual(slots.count, 6)
        XCTAssertEqual(slots.map(\.name), ["USER 1", "USER 2", "USER 3", "USER 4", "USER 5", "USER 6"])
        XCTAssertTrue(slots.allSatisfy(\.isEmpty))
    }

    func testNothingSavedReadsAsEmptySlots() {
        let prefs = PreferencesStore(defaults: makeScratchDefaults())
        XCTAssertEqual(prefs.customEQPresets, CustomEQPreset.emptySlots)
    }

    /// Before 2.3.1 RC 1 there were three slots. Someone updating keeps the
    /// three they saved and finds three new empty ones after them.
    func testThreeSlotsSavedByAnOlderBuildArePaddedToSix() throws {
        let defaults = makeScratchDefaults()
        let saved = [
            CustomEQPreset(name: "HD650", gains: Array(repeating: 1.5, count: 12)),
            CustomEQPreset(name: "USER 2"),
            CustomEQPreset(name: "CAR", gains: Array(repeating: -2, count: 12)),
        ]
        defaults.set(try JSONEncoder().encode(saved), forKey: "cratedigger.eq.custom")

        let slots = PreferencesStore(defaults: defaults).customEQPresets
        XCTAssertEqual(slots.count, CustomEQPreset.slotCount)
        XCTAssertEqual(Array(slots.prefix(3)), saved)
        XCTAssertEqual(slots.dropFirst(3).map(\.name), ["USER 4", "USER 5", "USER 6"])
        XCTAssertTrue(slots.dropFirst(3).allSatisfy(\.isEmpty))
    }

    func testSixSlotsRoundTrip() {
        let prefs = PreferencesStore(defaults: makeScratchDefaults())
        var slots = CustomEQPreset.emptySlots
        slots[5] = CustomEQPreset(name: "IEM", gains: Array(repeating: 3, count: 12))
        prefs.customEQPresets = slots
        XCTAssertEqual(prefs.customEQPresets, slots)
    }
}
