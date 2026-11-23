import Foundation
import SystemPermissions
import XCTest

final class CustomPermissionTests: XCTestCase {
  func testConstructionUsesCapabilityAndDeduplicatesUsageDescriptionKeys() throws {
    let capability = PermissionCapability(
      supportsStatusCheck: true,
      supportsRequest: true,
      systemSettingsURL: URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
      requiresRelaunch: true
    )
    let descriptor = try CustomPermission(
      identifier: "custom.permission",
      capability: capability,
      usageDescriptionKeys: [.camera, .microphone, .camera]
    )
    let type = PermissionType.custom(descriptor)

    XCTAssertEqual(descriptor.usageDescriptionKeys, [.camera, .microphone])
    XCTAssertEqual(type.capability, capability)
    XCTAssertEqual(type.usageDescriptionKeys(for: .none), [.camera, .microphone])
  }

  func testHostKeyMetadataPreservesExactSpellingAndFirstOccurrence() throws {
    let host = try XCTUnwrap(UsageDescriptionKey(rawValue: "HostUsageKey"))
    let composed = try XCTUnwrap(UsageDescriptionKey(rawValue: "Fixture\u{e9}"))
    let decomposed = try XCTUnwrap(UsageDescriptionKey(rawValue: "Fixturee\u{301}"))
    XCTAssertNotEqual(composed, decomposed)
    XCTAssertEqual(Set([composed, decomposed]).count, 2)
    let type = PermissionType.custom(
      try CustomPermission(
        identifier: "com.example.privacy", capability: testCapability,
        usageDescriptionKeys: [.camera, host, composed, host, decomposed]))
    let data = try JSONEncoder().encode(type)
    let decoded = try JSONDecoder().decode(PermissionType.self, from: data)
    XCTAssertEqual(
      try decoded.metadata(on: .macOS).usageDescriptionKeys,
      [.camera, host, composed, decomposed])
  }

  func testOversizedKeyListIsRejectedBeforeDeduplication() {
    XCTAssertThrowsError(
      try CustomPermission(
        identifier: "com.example.privacy", capability: testCapability,
        usageDescriptionKeys: Array(repeating: .camera, count: 65))
    ) { error in
      XCTAssertEqual((error as? PermissionContractError)?.code, "limitExceeded")
    }
  }

  func testEqualityAndHashUseStableIdentifierIdentity() throws {
    let capability = PermissionCapability(
      supportsStatusCheck: false,
      supportsRequest: false,
      systemSettingsURL: nil,
      requiresRelaunch: true
    )
    let first = try CustomPermission(
      identifier: "custom.permission",
      capability: capability,
      usageDescriptionKeys: [.camera, .microphone]
    )
    let second = try CustomPermission(
      identifier: "custom.permission",
      capability: capability,
      usageDescriptionKeys: [.camera, .microphone]
    )
    let sameIdentityWithDifferentMetadata = try CustomPermission(
      identifier: "custom.permission",
      capability: .init(
        supportsStatusCheck: true,
        supportsRequest: true,
        systemSettingsURL: URL(string: "x-test:settings"),
        requiresRelaunch: false
      ),
      usageDescriptionKeys: [.camera]
    )
    let differentIdentity = try CustomPermission(
      identifier: "custom.other-permission",
      capability: capability,
      usageDescriptionKeys: [.camera, .microphone]
    )

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.hashValue, second.hashValue)
    XCTAssertEqual(first, sameIdentityWithDifferentMetadata)
    XCTAssertEqual(first.hashValue, sameIdentityWithDifferentMetadata.hashValue)
    XCTAssertNotEqual(first, differentIdentity)
  }

  func testValidationBridgesRustReason() {
    XCTAssertNil(CustomPermission.validationError(for: "com.example.permission"))
    XCTAssertEqual(CustomPermission.validationError(for: "custom..permission"), .emptySegment)
  }

  func testInitializerThrowsConcreteValidationError() {
    XCTAssertThrowsError(
      try CustomPermission(identifier: "custom permission", capability: testCapability)
    ) { error in
      XCTAssertEqual(error as? CustomPermission.IdentifierValidationError, .invalidCharacter)
    }

    XCTAssertThrowsError(
      try CustomPermission(identifier: PermissionType.camera.id, capability: testCapability)
    ) { error in
      XCTAssertEqual(error as? CustomPermission.IdentifierValidationError, .reserved)
    }
  }
}

private let testCapability = PermissionCapability(
  supportsStatusCheck: false,
  supportsRequest: false,
  systemSettingsURL: nil,
  requiresRelaunch: false
)
