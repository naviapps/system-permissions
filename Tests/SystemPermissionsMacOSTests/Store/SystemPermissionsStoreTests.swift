import Combine
import SystemPermissions
import SystemPermissionsMacOS
import XCTest

final class SystemPermissionsStoreTests: XCTestCase {
  @MainActor
  func testInitializerDoesNotRefreshUntilRequestedAndDeduplicatesTrackedTypes() throws {
    let permissions = CountingPermissionChecker()
    let store = try SystemPermissionsStore(
      trackedTypes: [.accessibility, .screenRecording, .accessibility],
      permissionChecker: permissions
    )

    XCTAssertEqual(store.trackedTypes, [.accessibility, .screenRecording])
    XCTAssertEqual(store.status(for: .accessibility), .supported(.unknown))
    XCTAssertNil(store.status(for: .notifications))
    XCTAssertEqual(store.allowsAccess(.accessibility), false)
    XCTAssertNil(store.allowsAccess(.notifications))
    XCTAssertTrue(permissions.statusCalls.isEmpty)
  }

  @MainActor
  func testRefreshAllUsesTrackedTypes() async throws {
    let permissions = StubPermissionChecker(statuses: [
      .accessibility: .granted,
      .screenRecording: .denied,
    ])
    let store = try SystemPermissionsStore(
      trackedTypes: [.accessibility, .screenRecording],
      permissionChecker: permissions
    )

    let refreshed = try await store.refreshAll()

    XCTAssertEqual(refreshed[.accessibility], .supported(.granted))
    XCTAssertEqual(refreshed[.screenRecording], .supported(.denied))
    XCTAssertEqual(store.allowsAccess(.accessibility), true)
    XCTAssertEqual(store.allowsAccess(.screenRecording), false)
    XCTAssertEqual(store.status(for: .screenRecording), .supported(.denied))
  }

  @MainActor
  func testScopedProvidersReceiveCanonicalUsageDescriptionKeys() async throws {
    let custom = try CustomPermission(
      identifier: "com.example.permissions",
      capability: .init(
        supportsStatusCheck: true, supportsRequest: true, systemSettingsURL: nil,
        requiresRelaunch: false), usageDescriptionKeys: [.camera, .microphone, .camera])
    let permission = PermissionType.custom(custom)
    let checker = CountingPermissionChecker()
    let store = try SystemPermissionsStore(trackedTypes: [permission], permissionChecker: checker)

    try await store.refreshAll()
    try await store.refresh(permission)
    try await store.requestAccess(for: permission)

    XCTAssertEqual(checker.statusCalls.count, 2)
    XCTAssertEqual(checker.requestCalls.count, 1)
    for received in checker.statusCalls + checker.requestCalls {
      guard case .custom(let value) = received else {
        return XCTFail("The provider received the wrong permission.")
      }
      XCTAssertEqual(value.usageDescriptionKeys, [.camera, .microphone])
    }
  }

  @MainActor
  func testRefreshSelectedTypesLeavesOtherTrackedStateUnknown() async throws {
    let permissions = StubPermissionChecker(statuses: [
      .accessibility: .granted,
      .screenRecording: .granted,
    ])
    let store = try SystemPermissionsStore(
      trackedTypes: [.accessibility, .screenRecording],
      permissionChecker: permissions
    )

    let result = try await store.refresh(.screenRecording)

    XCTAssertEqual(result, .supported(.granted))
    XCTAssertEqual(store.status(for: .accessibility), .supported(.unknown))
    XCTAssertEqual(store.status(for: .screenRecording), .supported(.granted))
  }

  @MainActor
  func testRefreshIgnoresUntrackedTypes() async throws {
    let permissions = OptionRecordingPermissionChecker(statuses: [
      .notifications: .granted,
      .screenRecording: .granted,
    ])
    let store = try SystemPermissionsStore(
      trackedTypes: [.screenRecording],
      permissionChecker: permissions
    )

    let result = try await store.refresh(.notifications)

    XCTAssertNil(result)
    XCTAssertNil(store.status(for: .notifications))
    XCTAssertEqual(store.status(for: .screenRecording), .supported(.unknown))
    XCTAssertNil(permissions.statusOptions[.notifications])
  }

  @MainActor
  func testRefreshUsesPermissionDefaultOptions() async throws {
    let permissions = OptionRecordingPermissionChecker(statuses: [.notifications: .granted])
    let store = try SystemPermissionsStore(
      trackedTypes: [.notifications],
      permissionChecker: permissions
    )

    try await store.refreshAll()

    XCTAssertEqual(permissions.statusOptions[.notifications], .notifications(.default))
  }

  @MainActor
  func testRequestUpdatesStatusAndUsesDefaultOptions() async throws {
    let permissions = OptionRecordingPermissionChecker(statuses: [.notifications: .granted])
    let store = try SystemPermissionsStore(
      trackedTypes: [.notifications],
      permissionChecker: permissions
    )

    let result = try await store.requestAccess(for: .notifications)

    XCTAssertEqual(result, .supported(.granted))
    XCTAssertEqual(store.allowsAccess(.notifications), true)
    XCTAssertEqual(permissions.permissionOptions[.notifications], .notifications(.default))
  }

  @MainActor
  func testAddOnlyPhotosRequestDoesNotPublishReadWriteAccess() async throws {
    let permissions = OptionRecordingPermissionChecker(
      statuses: [.photos: .denied], requestStatuses: [.photos: .granted])
    let store = try SystemPermissionsStore(
      trackedTypes: [.photos],
      permissionChecker: permissions
    )
    try await store.refresh(.photos)
    var publications = 0
    let subscription = store.objectWillChange.sink { publications += 1 }

    let result = try await store.requestAccess(for: .photos, options: .photos(.addOnly))

    XCTAssertEqual(result, .supported(.granted))
    XCTAssertEqual(permissions.permissionOptions[.photos], .photos(.addOnly))
    XCTAssertEqual(permissions.statusOptions[.photos], .photos(.readWrite))
    XCTAssertEqual(permissions.statusCallCount, 1)
    XCTAssertEqual(store.status(for: .photos), .supported(.denied))
    XCTAssertEqual(store.allowsAccess(.photos), false)
    XCTAssertEqual(publications, 0)
    withExtendedLifetime(subscription) {}
  }

  @MainActor
  func testRequestCanUseExplicitNoOptions() async throws {
    let permissions = OptionRecordingPermissionChecker(statuses: [.notifications: .granted])
    let store = try SystemPermissionsStore(
      trackedTypes: [.notifications],
      permissionChecker: permissions
    )

    try await store.requestAccess(for: .notifications, options: PermissionOptions.none)

    XCTAssertEqual(permissions.permissionOptions[.notifications], PermissionOptions.none)
  }

  @MainActor
  func testPartiallyAuthorizedStatusesAllowAccess() async throws {
    let permissions = StubPermissionChecker(statuses: [
      .photos: .limited,
      .notifications: .provisional,
    ])
    let store = try SystemPermissionsStore(
      trackedTypes: [.photos, .notifications],
      permissionChecker: permissions
    )

    try await store.refreshAll()

    XCTAssertEqual(store.allowsAccess(.photos), true)
    XCTAssertEqual(store.allowsAccess(.notifications), true)
  }

  @MainActor
  func testRequestIgnoresUntrackedTypes() async throws {
    let permissions = OptionRecordingPermissionChecker(statuses: [.notifications: .granted])
    let store = try SystemPermissionsStore(
      trackedTypes: [.screenRecording],
      permissionChecker: permissions
    )

    let result = try await store.requestAccess(for: .notifications)

    XCTAssertNil(store.status(for: .notifications))
    XCTAssertNil(result)
    XCTAssertNil(permissions.permissionOptions[.notifications])
  }

  @MainActor
  func testUnsupportedOrFailedRequestStoresResult() async throws {
    let permissions = StubPermissionChecker(requestResults: [
      .automation(targetApplication: "com.example.target"): .unsupported(
        PermissionType.automation(targetApplication: "com.example.target").capability),
      .screenRecording: .failed(.apiUnavailable),
    ])
    let store = try SystemPermissionsStore(
      trackedTypes: [.automation(targetApplication: "com.example.target"), .screenRecording],
      permissionChecker: permissions
    )

    try await store.requestAccess(for: .automation(targetApplication: "com.example.target"))
    try await store.requestAccess(for: .screenRecording)

    XCTAssertEqual(
      store.status(for: .automation(targetApplication: "com.example.target")),
      .unsupported(PermissionType.automation(targetApplication: "com.example.target").capability)
    )
    XCTAssertEqual(store.status(for: .screenRecording), .failed(.apiUnavailable))
    XCTAssertNil(store.allowsAccess(.automation(targetApplication: "com.example.target")))
    XCTAssertNil(store.allowsAccess(.screenRecording))
  }

  @MainActor
  func testStateChangePublishesObjectWillChange() async throws {
    let permissions = StubPermissionChecker(requestResults: [
      .screenRecording: .failed(.apiUnavailable)
    ])
    let store = try SystemPermissionsStore(
      trackedTypes: [.screenRecording],
      permissionChecker: permissions
    )
    var didPublishChange = false
    let cancellable = store.objectWillChange.sink {
      didPublishChange = true
    }

    try await store.requestAccess(for: .screenRecording)

    XCTAssertTrue(didPublishChange)
    XCTAssertEqual(store.status(for: .screenRecording), .failed(.apiUnavailable))
    withExtendedLifetime(cancellable) {}
  }
}

private struct StubPermissionChecker: PermissionChecking {
  let statuses: [PermissionType: PermissionStatus]
  let requestResults: [PermissionType: PermissionOperationResult<PermissionStatus>]

  init(
    statuses: [PermissionType: PermissionStatus] = [:],
    requestResults: [PermissionType: PermissionOperationResult<PermissionStatus>] = [:]
  ) {
    self.statuses = statuses
    self.requestResults = requestResults
  }

  func status(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    .supported(statuses[type] ?? .denied)
  }

  func requestAccess(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    requestResults[type] ?? .supported(statuses[type] ?? .denied)
  }

  func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    .supported(true)
  }
}

private final class CountingPermissionChecker: PermissionChecking, @unchecked Sendable {
  private(set) var statusCalls: [PermissionType] = []
  private(set) var requestCalls: [PermissionType] = []

  func status(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    statusCalls.append(type)
    return .supported(.denied)
  }

  func requestAccess(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    requestCalls.append(type)
    return .supported(.denied)
  }

  func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    .supported(true)
  }
}

private final class OptionRecordingPermissionChecker: PermissionChecking, @unchecked Sendable {
  let statuses: [PermissionType: PermissionStatus]
  let requestStatuses: [PermissionType: PermissionStatus]
  private(set) var statusCallCount = 0
  private(set) var statusOptions: [PermissionType: PermissionOptions] = [:]
  private(set) var permissionOptions: [PermissionType: PermissionOptions] = [:]

  init(
    statuses: [PermissionType: PermissionStatus],
    requestStatuses: [PermissionType: PermissionStatus] = [:]
  ) {
    self.statuses = statuses
    self.requestStatuses = requestStatuses
  }

  func status(for type: PermissionType, options: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    statusCallCount += 1
    statusOptions[type] = options
    return .supported(statuses[type] ?? .denied)
  }

  func requestAccess(for type: PermissionType, options: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    permissionOptions[type] = options
    return .supported(requestStatuses[type] ?? statuses[type] ?? .denied)
  }

  func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    .supported(true)
  }
}

@MainActor
final class PermissionStoreConfigurationTests: XCTestCase {
  func testInvalidAutomationTargetIsRecoverableConfigurationError() {
    XCTAssertThrowsError(
      try SystemPermissionsStore(trackedTypes: [.automation(targetApplication: "")]))
    XCTAssertNoThrow(
      try SystemPermissionsStore(trackedTypes: [
        .automation(targetApplication: "com.example.Editor")
      ]))
  }

  func testAutomationTargetsHaveIndependentStoredState() async throws {
    let first = PermissionType.automation(targetApplication: "com.example.first")
    let second = PermissionType.automation(targetApplication: "com.example.second")
    let store = try SystemPermissionsStore(
      trackedTypes: [first, second],
      permissionChecker: PermissionChecker(
        environment: .init(
          status: { type, _ in .supported(type == first ? .granted : .denied) },
          requestAccess: { _, _ in .supported(.unknown) }, openURL: { _ in false })))
    try await store.refreshAll()
    XCTAssertEqual(store.status(for: first), .supported(.granted))
    XCTAssertEqual(store.status(for: second), .supported(.denied))
  }
}

@MainActor
final class PermissionStoreBatchBudgetTests: XCTestCase {
  func testOversizedBatchReportsFailureWithoutPartialPublication() async throws {
    let capability = PermissionCapability(
      supportsStatusCheck: true, supportsRequest: false,
      systemSettingsURL: URL(string: "x:" + String(repeating: "a", count: 950)),
      requiresRelaunch: false)
    let types = try (0..<400).map { index in
      PermissionType.custom(
        try CustomPermission(
          identifier: "com.example." + String(repeating: "a", count: 950) + String(index),
          capability: capability))
    }
    let store = try SystemPermissionsStore(
      trackedTypes: types,
      permissionChecker: PermissionChecker(
        environment: .init(
          status: { _, _ in .unsupported(capability) },
          requestAccess: { _, _ in .supported(.unknown) }, openURL: { _ in false })))
    do {
      try await store.refreshAll()
      XCTFail("Oversized atomic updates must report failure")
    } catch let error as PermissionContractError {
      XCTAssertEqual(error.code, "inputTooLarge")
    }
    XCTAssertEqual(store.status(for: types[0]), .supported(.unknown))
    XCTAssertEqual(store.status(for: types[399]), .supported(.unknown))
    try await store.refresh(types[0])
    XCTAssertEqual(store.status(for: types[0]), .unsupported(capability))
  }
}
