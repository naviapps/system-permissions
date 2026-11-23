import SystemPermissions
import XCTest

final class PermissionTypeMetadataTests: XCTestCase {
  func testMetadataBridgesPlatformOptionsAndTypedValues() throws {
    let options = PermissionOptions.photos(.addOnly)
    let macOS = try PermissionType.photos.metadata(on: .macOS, options: options)
    XCTAssertEqual(macOS.capability.systemSettingsURL?.scheme, "x-apple.systempreferences")
    XCTAssertEqual(macOS.usageDescriptionKeys, [.photosAddOnly])
    XCTAssertTrue(macOS.capability.supportsStatusCheck)

    let windows = try PermissionType.photos.metadata(on: .windows, options: options)
    XCTAssertNil(windows.capability.systemSettingsURL)
    XCTAssertTrue(windows.usageDescriptionKeys.isEmpty)
    XCTAssertFalse(windows.capability.supportsStatusCheck)
    XCTAssertThrowsError(try PermissionType.camera.metadata(on: .macOS, options: options)) {
      XCTAssertEqual(($0 as? PermissionContractError)?.code, "invalidOptions")
    }
  }
}
