import Foundation
import SystemPermissions
import XCTest

final class PermissionOptionsTests: XCTestCase {
  func testNotificationOptionsMatchSharedPortableFixture() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "notification-options", withExtension: "json"))
    let fixture = try JSONDecoder().decode(
      NotificationOptionsFixture.self, from: Data(contentsOf: url))
    let named: [String: NotificationRequestOptions] = [
      "alert": .alert, "badge": .badge, "sound": .sound,
      "criticalAlert": .criticalAlert, "provisional": .provisional,
      "providesAppNotificationSettings": .providesAppNotificationSettings,
    ]
    XCTAssertEqual(Set(fixture.namedOptions.map(\.name)), Set(named.keys))
    for item in fixture.namedOptions {
      let options = try XCTUnwrap(named[item.name])
      XCTAssertEqual(options.rawValue, item.rawValue, item.name)
      try assertNotificationWire(options, expected: item.rawValue)
    }
    for item in fixture.combinations {
      let options = try item.names.reduce(into: NotificationRequestOptions()) {
        $0.formUnion(try XCTUnwrap(named[$1]))
      }
      try assertNotificationWire(options, expected: item.rawValue)
    }
    for mask in fixture.rawMasks {
      try assertNotificationWire(.init(rawValue: mask), expected: mask)
    }
  }

  func testTypedDefaultsProjectRustMetadata() {
    XCTAssertEqual(PermissionType.notifications.defaultOptions, .notifications(.default))
    XCTAssertEqual(PermissionType.photos.defaultOptions, .photos(.default))
  }

  func testNotificationOptionsCodableRoundTripsRawValues() throws {
    let options: NotificationRequestOptions = [.alert, .sound, .provisional]
    let data = try JSONEncoder().encode(options)

    XCTAssertEqual(String(data: data, encoding: .utf8), "\(options.rawValue)")
    XCTAssertEqual(try JSONDecoder().decode(NotificationRequestOptions.self, from: data), options)
  }

  func testPhotoAccessCasesAndRawValues() {
    XCTAssertEqual(PhotoAccessLevel.readWrite.rawValue, "readWrite")
    XCTAssertEqual(PhotoAccessLevel.addOnly.rawValue, "addOnly")
  }

  func testApplicabilityBridgesNativeValidation() {
    XCTAssertTrue(PermissionOptions.photos(.addOnly).applies(to: .photos))
    XCTAssertFalse(PermissionOptions.photos(.addOnly).applies(to: .notifications))
  }

  func testPermissionOptionsCodableUsesExplicitCaseAndPayloadKeys() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    XCTAssertEqual(
      String(data: try encoder.encode(PermissionOptions.none), encoding: .utf8),
      #"{"kind":"none"}"#
    )
    XCTAssertEqual(
      String(
        data: try encoder.encode(PermissionOptions.notifications([.alert, .sound])),
        encoding: .utf8
      ),
      #"{"kind":"notifications","notificationOptions":5}"#
    )
    XCTAssertEqual(
      String(data: try encoder.encode(PermissionOptions.photos(.addOnly)), encoding: .utf8),
      #"{"kind":"photos","photoAccessLevel":"addOnly"}"#
    )

    XCTAssertEqual(
      try JSONDecoder().decode(
        PermissionOptions.self,
        from: Data(#"{"kind":"notifications","notificationOptions":7}"#.utf8)
      ),
      .notifications([.alert, .badge, .sound])
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        PermissionOptions.self,
        from: Data(#"{"kind":"photos","photoAccessLevel":"readWrite"}"#.utf8)
      ),
      .photos(.readWrite)
    )
  }

  func testPermissionOptionsCodableRejectsInvalidPayloadShapes() {
    assertPermissionOptionsDecodeFails(#"{"kind":"unknown"}"#)
    assertPermissionOptionsDecodeFails(#"{"kind":"none","notificationOptions":1}"#)
    assertPermissionOptionsDecodeFails(#"{"kind":"notifications"}"#)
    assertPermissionOptionsDecodeFails(#"{"kind":"notifications","photoAccessLevel":"addOnly"}"#)
    assertPermissionOptionsDecodeFails(#"{"kind":"photos"}"#)
    assertPermissionOptionsDecodeFails(#"{"kind":"photos","notificationOptions":1}"#)
    assertPermissionOptionsDecodeFails(
      #"{"kind":"photos","photoAccessLevel":"addOnly","extra":true}"#)
  }

  private func assertPermissionOptionsDecodeFails(
    _ json: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try JSONDecoder().decode(PermissionOptions.self, from: Data(json.utf8)),
      file: file,
      line: line
    )
  }

  private func assertNotificationWire(
    _ options: NotificationRequestOptions, expected: UInt64
  ) throws {
    let data = try JSONEncoder().encode(PermissionOptions.notifications(options))
    let payload = try JSONDecoder().decode(NotificationWire.self, from: data)
    XCTAssertEqual(payload.kind, "notifications")
    XCTAssertEqual(payload.notificationOptions, expected)
    XCTAssertEqual(
      try JSONDecoder().decode(PermissionOptions.self, from: data),
      .notifications(.init(rawValue: expected)))
  }
}

private struct NotificationOptionsFixture: Decodable {
  struct NamedOption: Decodable {
    let name: String
    let rawValue: UInt64
  }
  struct Combination: Decodable {
    let names: [String]
    let rawValue: UInt64
  }
  let namedOptions: [NamedOption]
  let combinations: [Combination]
  let rawMasks: [UInt64]
}

private struct NotificationWire: Decodable {
  let kind: String
  let notificationOptions: UInt64
}

final class NotificationWidthTests: XCTestCase {
  func testFullUnsignedNotificationBitsRemainExactAcrossRustAndSwift() throws {
    let value = PermissionOptions.notifications(.init(rawValue: UInt64.max))
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(PermissionOptions.self, from: data), value)
    XCTAssertTrue(value.applies(to: .notifications))
  }
}
