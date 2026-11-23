import SystemPermissions
import SystemPermissionsMacOS
import XCTest

final class SystemPermissionsStoreConcurrencyTests: XCTestCase {
  @MainActor
  func testRefreshesSkipPermissionWithPendingRequestAndStillCheckOthers() async throws {
    let checker = RequestGatedPermissionChecker()
    let store = try SystemPermissionsStore(
      trackedTypes: [.accessibility, .screenRecording],
      permissionChecker: checker
    )
    let request = Task { try await store.requestAccess(for: .accessibility) }
    await checker.waitForRequest(1)

    let single = try await store.refresh(.accessibility)
    let batch = try await store.refreshAll()
    let callsDuringRequest = await checker.statusCalls
    XCTAssertEqual(single, .supported(.unknown))
    XCTAssertEqual(batch[.accessibility], .supported(.unknown))
    XCTAssertEqual(batch[.screenRecording], .supported(.denied))
    XCTAssertEqual(callsDuringRequest, [.screenRecording])

    await checker.finishRequest(1, with: .granted)
    let result = try await request.value
    XCTAssertEqual(result, .supported(.granted))
    XCTAssertEqual(store.status(for: .accessibility), .supported(.granted))

    let afterRequest = try await store.refresh(.accessibility)
    let finalCalls = await checker.statusCalls
    XCTAssertEqual(afterRequest, .supported(.denied))
    XCTAssertEqual(finalCalls, [.screenRecording, .accessibility])
  }

  @MainActor
  func testOlderRequestCompletionDoesNotUnblockRefreshDuringNewerRequest() async throws {
    let checker = RequestGatedPermissionChecker()
    let store = try SystemPermissionsStore(
      trackedTypes: [.accessibility], permissionChecker: checker)
    let earlier = Task { try await store.requestAccess(for: .accessibility) }
    await checker.waitForRequest(1)
    let later = Task { try await store.requestAccess(for: .accessibility) }
    await checker.waitForRequest(2)

    await checker.finishRequest(1, with: .denied)
    let earlierResult = try await earlier.value
    let refresh = try await store.refresh(.accessibility)
    let callsDuringRequest = await checker.statusCalls
    XCTAssertEqual(earlierResult, .supported(.unknown))
    XCTAssertEqual(refresh, .supported(.unknown))
    XCTAssertTrue(callsDuringRequest.isEmpty)

    await checker.finishRequest(2, with: .granted)
    let laterResult = try await later.value
    XCTAssertEqual(laterResult, .supported(.granted))
    XCTAssertEqual(store.status(for: .accessibility), .supported(.granted))
  }

  @MainActor
  func testNewerRequestCompletionAllowsRefreshBeforeOlderRequestFinishes() async throws {
    let checker = RequestGatedPermissionChecker()
    let store = try SystemPermissionsStore(
      trackedTypes: [.accessibility], permissionChecker: checker)
    let earlier = Task { try await store.requestAccess(for: .accessibility) }
    await checker.waitForRequest(1)
    let later = Task { try await store.requestAccess(for: .accessibility) }
    await checker.waitForRequest(2)

    await checker.finishRequest(2, with: .granted)
    let laterResult = try await later.value
    XCTAssertEqual(laterResult, .supported(.granted))
    let refreshed = try await store.refresh(.accessibility)
    XCTAssertEqual(refreshed, .supported(.denied))

    await checker.finishRequest(1, with: .limited)
    let earlierResult = try await earlier.value
    XCTAssertEqual(earlierResult, .supported(.denied))
    XCTAssertEqual(store.status(for: .accessibility), .supported(.denied))
    let calls = await checker.statusCalls
    XCTAssertEqual(calls, [.accessibility])
  }

  @MainActor
  func testPendingRequestDoesNotHideInvalidRefreshDescriptor() async throws {
    let identifier = "com.example.custom"
    let tracked = PermissionType.custom(
      try CustomPermission(
        identifier: identifier,
        capability: .init(
          supportsStatusCheck: true, supportsRequest: true,
          systemSettingsURL: nil, requiresRelaunch: false)))
    let conflicting = PermissionType.custom(
      try CustomPermission(
        identifier: identifier,
        capability: .init(
          supportsStatusCheck: true, supportsRequest: false,
          systemSettingsURL: nil, requiresRelaunch: false)))
    let descriptors: [(tracked: PermissionType, invalid: PermissionType, errorCode: String)] = [
      (tracked, conflicting, "inconsistentMetadata"),
      (
        .automation(targetApplication: "com.example.Keyboard"),
        .automation(targetApplication: "com.example.\u{212A}eyboard"),
        "invalidTargetApplication"
      ),
    ]
    for descriptor in descriptors {
      XCTAssertEqual(descriptor.tracked, descriptor.invalid)
      let checker = RequestGatedPermissionChecker()
      let store = try SystemPermissionsStore(
        trackedTypes: [descriptor.tracked], permissionChecker: checker)
      let request = Task { try await store.requestAccess(for: descriptor.tracked) }
      await checker.waitForRequest(1)

      do {
        _ = try await store.refresh(descriptor.invalid)
        XCTFail("An invalid descriptor must fail even if it compares equal to a pending type")
      } catch let error as PermissionContractError {
        XCTAssertEqual(error.code, descriptor.errorCode)
      } catch {
        XCTFail("Unexpected refresh error: \(error)")
      }
      let skipped = try? await store.refresh(descriptor.tracked)
      let callsDuringRequest = await checker.statusCalls
      XCTAssertEqual(skipped, .supported(.unknown))
      XCTAssertTrue(callsDuringRequest.isEmpty)

      await checker.finishRequest(1, with: .granted)
      let result = try await request.value
      XCTAssertEqual(result, .supported(.granted))
      XCTAssertEqual(store.status(for: descriptor.tracked), .supported(.granted))
    }
  }

  @MainActor
  func testRefreshAllDoesNotOverwriteNewerRequestWhileAnotherPermissionIsPending() async throws {
    let checker = GatedPermissionChecker()
    let store = try SystemPermissionsStore(
      trackedTypes: [.camera, .microphone],
      permissionChecker: checker
    )
    let refresh = Task { try await store.refreshAll() }
    await checker.waitForStatusRequest(.camera)
    await checker.waitForStatusRequest(.microphone)
    await checker.finishStatus(.camera, with: .granted)

    // Allow the batch to receive camera while the microphone request remains gated.
    for _ in 0..<20 { await Task.yield() }
    let requestResult = try await store.requestAccess(for: .camera)
    XCTAssertEqual(requestResult, .supported(.denied))
    await checker.finishStatus(.microphone, with: .granted)

    let results = try await refresh.value
    XCTAssertEqual(store.status(for: .camera), .supported(.denied))
    XCTAssertEqual(results[.camera], .supported(.denied))
    XCTAssertEqual(results[.microphone], .supported(.granted))
  }
}

private actor RequestGatedPermissionChecker: PermissionChecking {
  private typealias Result = PermissionOperationResult<PermissionStatus>
  private var requestCount = 0
  private var pendingRequests: [Int: CheckedContinuation<Result, Never>] = [:]
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private(set) var statusCalls: [PermissionType] = []

  func status(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    statusCalls.append(type)
    return .supported(.denied)
  }

  func requestAccess(for _: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    requestCount += 1
    let index = requestCount
    return await withCheckedContinuation { continuation in
      pendingRequests[index] = continuation
      waiters.removeValue(forKey: index)?.resume()
    }
  }

  func waitForRequest(_ index: Int) async {
    if pendingRequests[index] != nil { return }
    await withCheckedContinuation { waiters[index] = $0 }
  }

  func finishRequest(_ index: Int, with status: PermissionStatus) {
    pendingRequests.removeValue(forKey: index)?.resume(returning: .supported(status))
  }

  nonisolated func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    XCTFail("The store must not open System Settings")
    return .supported(false)
  }
}

private actor GatedPermissionChecker: PermissionChecking {
  private var requests:
    [PermissionType: CheckedContinuation<PermissionOperationResult<PermissionStatus>, Never>] = [:]
  private var requestWaiters: [PermissionType: [CheckedContinuation<Void, Never>]] = [:]

  func status(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    await withCheckedContinuation { continuation in
      requests[type] = continuation
      for waiter in requestWaiters.removeValue(forKey: type) ?? [] {
        waiter.resume()
      }
    }
  }

  func waitForStatusRequest(_ type: PermissionType) async {
    if requests[type] != nil { return }
    await withCheckedContinuation { continuation in
      requestWaiters[type, default: []].append(continuation)
    }
  }

  func finishStatus(_ type: PermissionType, with status: PermissionStatus) {
    requests.removeValue(forKey: type)?.resume(returning: .supported(status))
  }

  func requestAccess(for _: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    .supported(.denied)
  }

  nonisolated func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    .supported(true)
  }
}
