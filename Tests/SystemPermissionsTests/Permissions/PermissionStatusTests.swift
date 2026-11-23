import SystemPermissions
import XCTest

final class PermissionStatusTests: XCTestCase {
  func testCasesAndRawValuesAreCanonical() {
    XCTAssertEqual(
      [
        PermissionStatus.granted,
        .limited,
        .provisional,
        .ephemeral,
        .denied,
        .restricted,
        .notDetermined,
        .unknown,
      ].map(\.rawValue),
      [
        "granted",
        "limited",
        "provisional",
        "ephemeral",
        "denied",
        "restricted",
        "notDetermined",
        "unknown",
      ]
    )
  }

  func testAccessQueryBridgesStatusAndBoolean() {
    XCTAssertTrue(PermissionStatus.limited.allowsAccess)
    XCTAssertFalse(PermissionStatus.unknown.allowsAccess)
  }
}
