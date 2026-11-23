import SystemPermissions
import XCTest

final class UsageDescriptionKeyTests: XCTestCase {
  func testNamedKeysMatchNativeMetadataInDeclarationOrder() throws {
    let catalog: [(PermissionType, UsageDescriptionKey)] = [
      (.camera, .camera),
      (.microphone, .microphone),
      (.contacts, .contacts),
      (.calendars, .calendarsFullAccess),
      (.reminders, .remindersFullAccess),
      (.photos, .photos),
      (.photos, .photosAddOnly),
      (.speechRecognition, .speechRecognition),
      (.location, .location),
      (.bluetooth, .bluetooth),
      (.localNetwork, .localNetwork),
      (.mediaLibrary, .mediaLibrary),
      (.systemAudioCapture, .systemAudioCapture),
      (.desktopFolder, .desktopFolder),
      (.documentsFolder, .documentsFolder),
      (.downloadsFolder, .downloadsFolder),
      (.networkVolumes, .networkVolumes),
      (.removableVolumes, .removableVolumes),
      (.fileProviderDomain, .fileProviderDomain),
      (.automation(targetApplication: "com.example.Editor"), .appleEvents),
    ]

    XCTAssertEqual(UsageDescriptionKey.allCases, catalog.map { $0.1 })
    for (permission, key) in catalog {
      let options: PermissionOptions = key == .photosAddOnly ? .photos(.addOnly) : .none
      let metadata = try permission.metadata(on: .macOS, options: options)
      XCTAssertEqual(metadata.usageDescriptionKeys, [key], permission.id)
    }
  }

  func testHostKeyUsesTheSameRawValueAndSingleValueCodableContract() throws {
    let rawValue = "HostUsageKey😀"
    let key = try XCTUnwrap(UsageDescriptionKey(rawValue: rawValue))
    let encoder = JSONEncoder()
    let serialized = try encoder.encode(key)
    XCTAssertEqual(serialized, try encoder.encode(rawValue))
    XCTAssertEqual(try JSONDecoder().decode(UsageDescriptionKey.self, from: serialized), key)
    XCTAssertFalse(UsageDescriptionKey.allCases.contains(key))

    let invalid = "Host\nUsageKey"
    XCTAssertNil(UsageDescriptionKey(rawValue: invalid))
    XCTAssertThrowsError(
      try JSONDecoder().decode(UsageDescriptionKey.self, from: encoder.encode(invalid)))
  }

  func testJSONRejectsUnpairedSurrogatesAndPreservesValidScalars() throws {
    let decoder = JSONDecoder()
    for invalid in [#""Host\uD800""#, #""Host\uDC00""#] {
      XCTAssertThrowsError(
        try decoder.decode(UsageDescriptionKey.self, from: Data(invalid.utf8)))
    }
    for (json, expected) in [(#""Host\uFFFD""#, "Host\u{FFFD}"), (#""Host\uD83D\uDE00""#, "Host😀")]
    {
      let key = try decoder.decode(UsageDescriptionKey.self, from: Data(json.utf8))
      XCTAssertEqual(Array(key.rawValue.utf8), Array(expected.utf8))
    }
  }
}
