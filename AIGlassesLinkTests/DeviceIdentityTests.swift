import Foundation
import XCTest
@testable import AIGlassesLink

final class DeviceIdentityTests: XCTestCase {
    func testSensorURLCarriesSourceAndDevice() throws {
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let url = try XCTUnwrap(DeviceIdentity.phoneSensorURL(
            base: URL(string: "https://ai-glasses-for-research.fly.dev")!,
            deviceID: id
        ))
        XCTAssertEqual(
            url.absoluteString,
            "wss://ai-glasses-for-research.fly.dev/ws/camera_thermal?source=phone&device=\(id)"
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "device" }?.value, id)
    }

    func testDeviceIDStaysTheSameForTheInstall() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let vendor = UUID()
        let first = DeviceIdentity.resolve(defaults: defaults, vendorID: vendor)
        XCTAssertEqual(first, vendor.uuidString)
        // Later reads return the saved value, even if identifierForVendor is unavailable or differs.
        XCTAssertEqual(DeviceIdentity.resolve(defaults: defaults, vendorID: nil), first)
        XCTAssertEqual(DeviceIdentity.resolve(defaults: defaults, vendorID: UUID()), first)
    }

    func testNilVendorIDFallsBackToASavedUUID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let id = DeviceIdentity.resolve(defaults: defaults, vendorID: nil)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(DeviceIdentity.resolve(defaults: defaults, vendorID: UUID()), id)
    }

    func testAppStartLogsDeviceID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let writer = try PhoneCaptureWriter(
            sessionID: "T01_P01",
            trial: TrialFormData(trial: "T01", pid: "P01"),
            deviceID: "DEVICE-1",
            rootURL: root
        )
        writer.close()
        let events = try PhoneCaptureUploadPackage.jsonLines(
            in: writer.directoryURL.appendingPathComponent("phone.jsonl")
        )
        let start = try XCTUnwrap(events.first { $0["event"] as? String == "app_start" })
        XCTAssertEqual(start["device_id"] as? String, "DEVICE-1")
    }
}
