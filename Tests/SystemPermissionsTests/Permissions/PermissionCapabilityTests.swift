import Foundation
import SystemPermissions
import XCTest

final class PermissionCapabilityTests: XCTestCase {
  func testCodableRoundTripsPublicMetadata() throws {
    let capability = PermissionCapability(
      supportsStatusCheck: true,
      supportsRequest: false,
      systemSettingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security"),
      requiresRelaunch: true
    )

    let data = try JSONEncoder().encode(capability)

    XCTAssertEqual(try JSONDecoder().decode(PermissionCapability.self, from: data), capability)
  }

  func testDescriptorAndCapabilityPreserveExactSettingsDestination() throws {
    func decode(_ destination: String) throws -> PermissionType {
      try JSONDecoder().decode(
        PermissionType.self,
        from: Data(
          """
          {"id":"com.example.settings","custom":{
            "capability":{"supportsStatusCheck":true,"supportsRequest":false,
              "systemSettingsUrl":"\(destination)","requiresRelaunch":false},
            "usageDescriptionKeys":[]
          }}
          """.utf8))
    }
    let original = "example:é"
    let escaped = "example:%C3%A9"
    let literalType = try decode(original)
    let escapedType = try decode(escaped)
    let equivalentType = try decode(original)
    let literal = try literalType.metadata(on: .macOS).capability
    let equivalent = try equivalentType.metadata(on: .macOS).capability
    let encoded = try JSONEncoder().encode(literal)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(json["systemSettingsUrl"] as? String, original)
    XCTAssertEqual(literal.systemSettingsURLString, original)
    XCTAssertEqual(literal.systemSettingsURL?.absoluteString, escaped)
    XCTAssertEqual(literalType, escapedType)
    XCTAssertEqual(literal, equivalent)
    XCTAssertTrue(Set([literal]).contains(equivalent))
    XCTAssertNotEqual(literal, try escapedType.metadata(on: .macOS).capability)
    let decomposed = try decode("example:e\u{0301}").metadata(on: .macOS).capability
    XCTAssertNotEqual(literal, decomposed)
  }
}
