import XCTest
@testable import Lilo

final class DeviceSetupMemoryTests: XCTestCase {
    private let airPods = DeviceSetupMemory.DeviceRef(uid: "airpods", name: "AirPods Pro")
    private let start = Date(timeIntervalSince1970: 1_000)

    func testSetupKeyIgnoresDisplayOrderAndNamesTheBuiltInSetup() {
        XCTAssertEqual(DeviceSetupMemory.setupKey(externalDisplayUUIDs: []), "builtin")
        XCTAssertEqual(
            DeviceSetupMemory.setupKey(externalDisplayUUIDs: ["B", "A"]),
            DeviceSetupMemory.setupKey(externalDisplayUUIDs: ["A", "B"])
        )
    }

    func testRecordsAUserChoiceForTheCurrentSetup() {
        var memory = DeviceSetupMemory()
        let recorded = memory.record(
            airPods, role: .output, setupKey: "desk", label: "Studio Display",
            now: start, lastAppliedAt: .distantPast, lastDevicesChangedAt: .distantPast
        )
        XCTAssertTrue(recorded)
        XCTAssertEqual(memory.setup(for: "desk")?.devices[.output], airPods)
        XCTAssertEqual(memory.setup(for: "desk")?.label, "Studio Display")
        XCTAssertNil(memory.setup(for: "builtin"))
    }

    func testIgnoresTheEchoOfItsOwnApply() {
        var memory = DeviceSetupMemory()
        let recorded = memory.record(
            airPods, role: .output, setupKey: "desk", label: "",
            now: start, lastAppliedAt: start.addingTimeInterval(-1), lastDevicesChangedAt: .distantPast
        )
        XCTAssertFalse(recorded)
        XCTAssertNil(memory.setup(for: "desk"))
    }

    func testIgnoresSwitchesRightAfterADeviceAppearsOrVanishes() {
        var memory = DeviceSetupMemory()
        XCTAssertFalse(memory.record(
            airPods, role: .input, setupKey: "desk", label: "",
            now: start, lastAppliedAt: .distantPast, lastDevicesChangedAt: start.addingTimeInterval(-2)
        ))
        XCTAssertTrue(memory.record(
            airPods, role: .input, setupKey: "desk", label: "",
            now: start, lastAppliedAt: .distantPast, lastDevicesChangedAt: start.addingTimeInterval(-4)
        ))
    }

    func testRoundTripsThroughJSONAndForgets() {
        var memory = DeviceSetupMemory()
        memory.record(
            airPods, role: .camera, setupKey: "desk", label: "Studio Display",
            now: start, lastAppliedAt: .distantPast, lastDevicesChangedAt: .distantPast
        )
        XCTAssertTrue(memory.json.contains("\"camera\""))
        var restored = DeviceSetupMemory(json: memory.json)
        XCTAssertEqual(restored, memory)

        restored.forget("desk")
        XCTAssertNil(restored.setup(for: "desk"))
        XCTAssertEqual(DeviceSetupMemory(json: "not json"), DeviceSetupMemory())
    }
}
