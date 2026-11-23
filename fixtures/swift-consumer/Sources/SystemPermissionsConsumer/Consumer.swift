import Foundation
import SystemPermissions
import SystemPermissionsMacOS

private struct AcceptanceFailure: Error {
  let message: String
}

private func require(_ condition: Bool, _ message: String) throws {
  guard condition else { throw AcceptanceFailure(message: message) }
}

private actor StatusCalls {
  private(set) var count = 0
  func record() { count += 1 }
}

private struct FixedStatusChecker: PermissionStatusChecking {
  let result: PermissionOperationResult<PermissionStatus>
  var calls: StatusCalls? = nil

  func status(for _: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    await calls?.record()
    return result
  }
}

@main
struct SystemPermissionsConsumer {
  @MainActor
  static func main() async throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let metadata = try PermissionType.camera.metadata(on: .macOS)
    try require(metadata.capability.supportsStatusCheck, "The native metadata core was not loaded")

    let namedOptions: [(NotificationRequestOptions, UInt64)] = [
      (.alert, 1), (.badge, 2), (.sound, 4), (.criticalAlert, 8),
      (.provisional, 16), (.providesAppNotificationSettings, 32),
      ([.alert, .sound], 5), ([.alert, .badge, .sound], 7),
      ([.criticalAlert, .provisional, .providesAppNotificationSettings], 56),
    ]
    for (option, expected) in namedOptions {
      try require(option.rawValue == expected, "A notification wire bit changed")
    }
    for mask in [UInt64(0), 64, 1 << 63, UInt64.max] {
      let raw = NotificationRequestOptions(rawValue: mask)
      let rawData = try encoder.encode(raw)
      try require(
        String(data: rawData, encoding: .utf8) == String(mask),
        "Notification Codable did not encode an exact unsigned integer")
      let options = PermissionOptions.notifications(raw)
      let encoded = try encoder.encode(options)
      let decoded = try decoder.decode(PermissionOptions.self, from: encoded)
      try require(decoded == options, "Notification Codable lost unsigned mask bits")
      try require(decoded.applies(to: .notifications), "The native contract rejected a raw mask")
    }
    let target = PermissionType.automation(targetApplication: "com.example.standalone")
    let encodedTarget = try encoder.encode(target)
    let decodedTarget = try decoder.decode(PermissionType.self, from: encodedTarget)
    try require(decodedTarget == target, "The native descriptor codec lost an Automation target")

    let replacementKey = try decoder.decode(
      UsageDescriptionKey.self, from: Data(#""Host\uFFFD""#.utf8))
    try require(replacementKey.rawValue == "Host\u{FFFD}", "A valid host key changed spelling")
    do {
      _ = try decoder.decode(UsageDescriptionKey.self, from: Data(#""Host\uD800""#.utf8))
      throw AcceptanceFailure(message: "The binding accepted an unpaired surrogate in a host key")
    } catch is DecodingError {}

    let customDescriptor = Data(
      """
      {"id":"com.example.standalone","custom":{
        "capability":{"supportsStatusCheck":true,"supportsRequest":false,
          "systemSettingsUrl":"example:é","requiresRelaunch":false},
        "usageDescriptionKeys":["NSCameraUsageDescription","HostUsageKey","HostUsageKey"]
      }}
      """.utf8)
    let custom = try PermissionType.decodeJSON(customDescriptor)
    do {
      _ = try PermissionType.decodeJSON(Data(#"{"id":"camera","id":"microphone"}"#.utf8))
      throw AcceptanceFailure(message: "The portable descriptor accepted a duplicate id")
    } catch let error as PermissionContractError where error.code == "invalidJson" {}
    let customMetadata = try custom.metadata(on: .windows)
    try require(
      customMetadata.usageDescriptionKeys.map(\.rawValue) == [
        "NSCameraUsageDescription", "HostUsageKey",
      ],
      "The native descriptor codec did not preserve custom usage description keys")
    try require(
      customMetadata.capability.systemSettingsURLString == "example:é",
      "The capability did not preserve the original Settings destination")
    let escapedDescriptor = Data(
      String(decoding: customDescriptor, as: UTF8.self).replacingOccurrences(
        of: "example:é", with: "example:%C3%A9"
      ).utf8)
    let escapedCustom = try decoder.decode(PermissionType.self, from: escapedDescriptor)

    let calls = StatusCalls()
    let checker = PermissionChecker(
      environment: PermissionEnvironment(
        status: { type, options in
          await calls.record()
          if type == .camera || (type == .photos && options == .photos(.addOnly)) {
            return .supported(.granted)
          }
          return .failed(.apiUnavailable)
        },
        requestAccess: { _, _ in
          preconditionFailure("The standalone fixture must not request permission")
        },
        openURL: { _ in
          preconditionFailure("The standalone fixture must not open Settings")
        }))
    do {
      _ = try SystemPermissionsStore(
        trackedTypes: [custom, escapedCustom], permissionChecker: checker)
      throw AcceptanceFailure(message: "Tracking accepted conflicting Settings destinations")
    } catch let error as PermissionContractError where error.code == "inconsistentMetadata" {}
    let store = try SystemPermissionsStore(
      trackedTypes: [.camera, .microphone, .photos], permissionChecker: checker)
    try require(
      store.status(for: .camera) == .supported(.unknown), "Store initialization refreshed")
    let initialCalls = await calls.count
    try require(initialCalls == 0, "Store initialization dispatched a status provider")
    try await store.refreshAll()
    try require(
      store.status(for: .camera) == .supported(.granted), "Injected success was not stored")
    try require(store.allowsAccess(.camera) == true, "Granted access was not projected")
    try require(
      store.status(for: .microphone) == .failed(.apiUnavailable),
      "An injected API failure became a permission denial")
    try require(store.allowsAccess(.microphone) == nil, "API failure advertised an access decision")

    let addOnly = try await store.refresh(.photos, options: .photos(.addOnly))
    try require(addOnly == .supported(.granted), "Add-only refresh did not return its own scope")
    try require(
      store.status(for: .photos) == .failed(.apiUnavailable),
      "An add-only grant was stored as read/write access")
    let mismatched = try await store.refresh(.camera, options: .photos(.addOnly))
    try require(mismatched == .failed(.invalidOptions), "Store dispatched mismatched options")

    let invalidOptions = await checker.status(for: .camera, options: .photos(.addOnly))
    try require(invalidOptions == .failed(.invalidOptions), "Invalid options were not rejected")
    do {
      _ = try SystemPermissionsStore(
        trackedTypes: [.automation(targetApplication: "")], permissionChecker: checker)
      throw AcceptanceFailure(message: "The native store accepted an empty Automation target")
    } catch is PermissionContractError {
      // Invalid descriptors fail before any provider or operating-system operation.
    }
    var rejectedObservation = PermissionStatusObserver.updates(
      for: [.camera, .automation(targetApplication: "")], using: checker
    ).makeAsyncIterator()
    let rejectedUpdate = await rejectedObservation.next()
    try require(rejectedUpdate == nil, "An invalid observation list emitted a status update")
    let finalCalls = await calls.count
    try require(finalCalls == 4, "Invalid inputs dispatched the injected status provider")

    let cancelledCalls = StatusCalls()
    var cancelledObservation = PermissionStatusObserver.updates(
      for: [.camera, .microphone],
      using: FixedStatusChecker(result: .supported(.granted), calls: cancelledCalls)
    ) { _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return .none
    }.makeAsyncIterator()
    let cancelledUpdate = await cancelledObservation.next()
    let cancelledStatusCalls = await cancelledCalls.count
    try require(
      cancelledUpdate == nil && cancelledStatusCalls == 0,
      "Cancelling during options must stop status checks")

    guard let relativeURL = URL(string: "relative/path") else {
      throw AcceptanceFailure(message: "Could not construct the malformed result fixture")
    }
    let malformedChecker = FixedStatusChecker(
      result: .unsupported(
        .init(
          supportsStatusCheck: false, supportsRequest: false, systemSettingsURL: relativeURL,
          requiresRelaunch: false)))
    var malformedObservation = PermissionStatusObserver.updates(
      for: [.camera], using: malformedChecker
    ).makeAsyncIterator()
    let malformedUpdate = await malformedObservation.next()
    try require(malformedUpdate == nil, "The observer emitted a malformed provider result")

    let windows: any PermissionChecking = PermissionChecker(
      environment: PermissionEnvironment(
        platform: .windows,
        status: { type, options in
          guard type == .location, options == .none else {
            preconditionFailure("The wrong platform's contract reached the provider")
          }
          return .supported(.restricted)
        },
        requestAccess: { _, _ in
          preconditionFailure("The standalone fixture must not request permission")
        },
        openURL: { $0.absoluteString == "ms-settings:privacy-location" }))
    let location = await windows.status(for: .location)
    try require(location == .supported(.restricted), "The Windows contract was not selected")
    let windowsAccessibility = try PermissionType.accessibility.metadata(on: .windows).capability
    let unsupported = await windows.status(for: .accessibility)
    try require(
      unsupported == .unsupported(windowsAccessibility), "A macOS-only effect reached the provider")
    let settings = try await windows.openSystemSettings(for: .location, options: .none)
    try require(settings == .supported(true), "The installed checker lost the Settings destination")
    print("Standalone SystemPermissions and SystemPermissionsMacOS acceptance passed.")
  }
}
