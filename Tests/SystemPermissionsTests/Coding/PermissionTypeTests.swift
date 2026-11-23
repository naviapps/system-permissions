import Foundation
import SystemPermissions
import XCTest

final class PermissionTypeTests: XCTestCase {
  func testDescriptorsRoundTripAcrossTheSharedContract() throws {
    let custom = try CustomPermission(
      identifier: "com.example.permission",
      capability: .init(
        supportsStatusCheck: true, supportsRequest: false,
        systemSettingsURL: URL(string: "x-example:settings"), requiresRelaunch: false),
      usageDescriptionKeys: [.camera])
    let types =
      PermissionType.builtIn + [
        .automation(targetApplication: "com.example.target"), .custom(custom),
      ]
    for type in types {
      XCTAssertEqual(
        try JSONDecoder().decode(PermissionType.self, from: JSONEncoder().encode(type)), type)
    }
    let published: [PermissionType] = try NativePermissions.call(["op": "builtIns"])
    XCTAssertFalse(published.isEmpty)
    XCTAssertEqual(PermissionType.builtIn, published)
  }

  func testAutomationTargetIsPartOfSwiftIdentity() {
    let first = PermissionType.automation(targetApplication: "com.example.first")
    let second = PermissionType.automation(targetApplication: "com.example.second")
    XCTAssertNotEqual(first, second)
    XCTAssertNotEqual(first.id, second.id)
  }

  func testMalformedDescriptorsAreRejectedBeforeNativeEffects() {
    for json in [
      #"{}"#,
      #"{"id":"automation","targetApplication":""}"#,
      #"{"id":"camera","unexpected":true}"#,
    ] {
      XCTAssertThrowsError(
        try JSONDecoder().decode(PermissionType.self, from: Data(json.utf8)), json)
    }
  }

  func testPortableDescriptorDecodingBridgesOriginalUTF8() throws {
    let input = #"""
      {"id":"com.example.custom","custom":{"capability":{"supportsStatusCheck":true,
        "supportsRequest":false,"systemSettingsUrl":"example:é","requiresRelaunch":false},
        "usageDescriptionKeys":["HostKey","HostKey"]}}
      """#
    let type = try PermissionType.decodeJSON(Data(input.utf8))
    let metadata = try type.metadata(on: .macOS)
    XCTAssertEqual(metadata.capability.systemSettingsURLString, "example:é")
    XCTAssertEqual(metadata.usageDescriptionKeys.map(\.rawValue), ["HostKey"])
    XCTAssertEqual(
      try PermissionType.decodeJSON(
        Data(#"{"id":"automation","targetApplication":"com.example.App"}"#.utf8)),
      .automation(targetApplication: "com.example.App"))

    for invalid in [
      #"{"id":"camera","id":"microphone"}"#,
      #"{"id":"camera"},"permission":{"id":"microphone"}"#,
    ] {
      XCTAssertThrowsError(try PermissionType.decodeJSON(Data(invalid.utf8)), invalid) { error in
        XCTAssertEqual((error as? PermissionContractError)?.code, "invalidJson")
      }
    }
    let invalidUTF8 = Data(#"{"id":"cam"#.utf8) + Data([0xFF]) + Data(#"era"}"#.utf8)
    XCTAssertThrowsError(try PermissionType.decodeJSON(invalidUTF8)) { error in
      XCTAssertEqual((error as? PermissionContractError)?.code, "invalidUtf8")
    }
    XCTAssertThrowsError(try PermissionType.decodeJSON(Data(repeating: 0x20, count: 1024 * 1024))) {
      error in
      XCTAssertEqual((error as? PermissionContractError)?.code, "inputTooLarge")
    }
  }
}
