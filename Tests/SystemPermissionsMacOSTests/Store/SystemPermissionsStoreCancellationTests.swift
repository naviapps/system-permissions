import Combine
import SystemPermissions
import SystemPermissionsMacOS
import XCTest

final class SystemPermissionsStoreCancellationTests: XCTestCase {
  @MainActor
  func testAlreadyCancelledOperationsDoNotInvokeCheckerOrPublish() async throws {
    let checker = CancellationTestChecker()
    let store = try SystemPermissionsStore(trackedTypes: [.camera], permissionChecker: checker)
    var publications = 0
    let subscription = store.objectWillChange.sink { publications += 1 }

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let refreshed = try await store.refresh(.camera)
      let requested = try await store.requestAccess(for: .camera)
      let batch = try await store.refreshAll()
      return (refreshed, requested, batch)
    }
    let (refreshed, requested, batch) = try await task.value

    XCTAssertEqual(refreshed, .supported(.unknown))
    XCTAssertEqual(requested, .supported(.unknown))
    XCTAssertEqual(batch, [.camera: .supported(.unknown)])
    let calls = await checker.calls
    XCTAssertTrue(calls.isEmpty)
    XCTAssertEqual(publications, 0)
    withExtendedLifetime(subscription) {}
  }

  @MainActor
  func testAlreadyCancelledOperationsDoNotSupersedePendingRefresh() async throws {
    let checker = CancellationTestChecker()
    let store = try SystemPermissionsStore(trackedTypes: [.camera], permissionChecker: checker)
    await checker.suspendNext(.status(.camera))
    let refresh = Task { try await store.refresh(.camera) }
    await checker.waitForCall(.status(.camera))
    await checker.setResult(.supported(.denied))

    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await store.refresh(.camera)
      try await store.requestAccess(for: .camera)
      try await store.refreshAll()
    }
    try await cancelled.value
    await checker.finish(.status(.camera), with: .supported(.limited))
    let result = try await refresh.value

    XCTAssertEqual(result, .supported(.limited))
    XCTAssertEqual(store.status(for: .camera), .supported(.limited))
    let calls = await checker.calls
    XCTAssertEqual(calls, [.status(.camera)])
  }

  @MainActor
  func testCancelledRefreshDiscardsLateResultsWithoutNotifyingObservers() async throws {
    try await assertCancelledOperation(.status(.camera))
  }

  @MainActor
  func testCancelledRequestDiscardsLateResultsWithoutNotifyingObservers() async throws {
    try await assertCancelledOperation(.request(.camera))
  }

  @MainActor
  func testCancelledBatchDiscardsResultsAndReturnsCurrentStoredState() async throws {
    let checker = CancellationTestChecker()
    let store = try SystemPermissionsStore(
      trackedTypes: [.camera, .microphone], permissionChecker: checker)
    var publications = 0
    let subscription = store.objectWillChange.sink { publications += 1 }
    await checker.suspendNext(.status(.camera))
    await checker.suspendNext(.status(.microphone))
    let batch = Task { try await store.refreshAll() }
    await checker.waitForCall(.status(.camera))
    await checker.waitForCall(.status(.microphone))

    await checker.finish(.status(.camera), with: .failed(.apiUnavailable))
    batch.cancel()
    let newerResult = try await store.refresh(.microphone)
    await checker.finish(.status(.microphone), with: .supported(.denied))
    let results = try await batch.value

    XCTAssertEqual(newerResult, .supported(.limited))
    XCTAssertEqual(results, [.camera: .supported(.unknown), .microphone: .supported(.limited)])
    XCTAssertEqual(store.status(for: .camera), .supported(.unknown))
    XCTAssertEqual(publications, 1)
    withExtendedLifetime(subscription) {}
  }

  @MainActor
  func testCancellingStartedRequestDoesNotRestoreSupersededRefresh() async throws {
    let checker = CancellationTestChecker()
    let store = try SystemPermissionsStore(trackedTypes: [.camera], permissionChecker: checker)
    await checker.suspendNext(.status(.camera))
    await checker.suspendNext(.request(.camera))
    let refresh = Task { try await store.refresh(.camera) }
    await checker.waitForCall(.status(.camera))
    let request = Task { try await store.requestAccess(for: .camera) }
    await checker.waitForCall(.request(.camera))

    request.cancel()
    await checker.finish(.status(.camera), with: .supported(.denied))
    let refreshed = try await refresh.value
    await checker.finish(.request(.camera), with: .supported(.granted))
    let requested = try await request.value

    XCTAssertEqual(refreshed, .supported(.unknown))
    XCTAssertEqual(requested, .supported(.unknown))
    XCTAssertEqual(store.status(for: .camera), .supported(.unknown))
  }

  @MainActor
  func testAddOnlyPhotosRefreshDoesNotPublishOrSupersedeReadWriteRefresh() async throws {
    let checker = CancellationTestChecker()
    let store = try SystemPermissionsStore(trackedTypes: [.photos], permissionChecker: checker)
    await checker.suspendNext(.status(.photos))
    let readWrite = Task { try await store.refresh(.photos) }
    await checker.waitForCall(.status(.photos))

    let addOnly = try await store.refresh(.photos, options: .photos(.addOnly))
    XCTAssertEqual(addOnly, .supported(.limited))
    XCTAssertEqual(store.status(for: .photos), .supported(.unknown))

    await checker.finish(.status(.photos), with: .supported(.denied))
    let result = try await readWrite.value
    XCTAssertEqual(result, .supported(.denied))
    XCTAssertEqual(store.status(for: .photos), .supported(.denied))
  }

  @MainActor
  func testMismatchedOptionsDoNotInvokeProvidersOrSupersedeRefresh() async throws {
    let checker = CancellationTestChecker()
    let store = try SystemPermissionsStore(trackedTypes: [.camera], permissionChecker: checker)
    await checker.suspendNext(.status(.camera))
    let valid = Task { try await store.refresh(.camera) }
    await checker.waitForCall(.status(.camera))

    let incorrectRefresh = try await store.refresh(.camera, options: .photos(.addOnly))
    let incorrectRequest = try await store.requestAccess(for: .camera, options: .photos(.addOnly))
    XCTAssertEqual(incorrectRefresh, .failed(.invalidOptions))
    XCTAssertEqual(incorrectRequest, .failed(.invalidOptions))
    XCTAssertEqual(store.status(for: .camera), .supported(.unknown))
    let calls = await checker.calls
    XCTAssertEqual(calls, [.status(.camera)])

    await checker.finish(.status(.camera), with: .supported(.denied))
    let result = try await valid.value
    XCTAssertEqual(result, .supported(.denied))
    XCTAssertEqual(store.status(for: .camera), .supported(.denied))
  }

  @MainActor
  func testCancellingAddOnlyPhotosRequestDoesNotSupersedeReadWriteRefresh() async throws {
    let checker = CancellationTestChecker()
    let store = try SystemPermissionsStore(trackedTypes: [.photos], permissionChecker: checker)
    await checker.suspendNext(.status(.photos))
    await checker.suspendNext(.request(.photos))
    let refresh = Task { try await store.refresh(.photos) }
    await checker.waitForCall(.status(.photos))
    let request = Task { try await store.requestAccess(for: .photos, options: .photos(.addOnly)) }
    await checker.waitForCall(.request(.photos))

    request.cancel()
    await checker.finish(.status(.photos), with: .supported(.denied))
    let refreshed = try await refresh.value
    await checker.finish(.request(.photos), with: .supported(.granted))
    let requested = try await request.value

    XCTAssertEqual(refreshed, .supported(.denied))
    XCTAssertEqual(requested, .supported(.unknown))
    XCTAssertEqual(store.status(for: .photos), .supported(.denied))
  }

  @MainActor
  private func assertCancelledOperation(
    _ operation: CancellationTestChecker.Operation,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let lateResults: [PermissionOperationResult<PermissionStatus>] = [
      .supported(.granted), .supported(.unknown), .failed(.apiUnavailable),
      .unsupported(PermissionType.camera.capability),
    ]
    for lateResult in lateResults {
      let checker = CancellationTestChecker()
      let store = try SystemPermissionsStore(trackedTypes: [.camera], permissionChecker: checker)
      try await store.refresh(.camera)
      var firstObserverPublications = 0
      var secondObserverPublications = 0
      let firstSubscription = store.objectWillChange.sink { firstObserverPublications += 1 }
      let secondSubscription = store.objectWillChange.sink { secondObserverPublications += 1 }
      await checker.suspendNext(operation)
      let task = Task {
        switch operation {
        case .status:
          return try await store.refresh(.camera)
        case .request:
          return try await store.requestAccess(for: .camera)
        }
      }
      await checker.waitForCall(operation)

      task.cancel()
      // The provider intentionally ignores cancellation until explicitly resumed.
      await checker.finish(operation, with: lateResult)
      let result = try await task.value

      XCTAssertEqual(result, .supported(.limited), file: file, line: line)
      XCTAssertEqual(store.status(for: .camera), .supported(.limited), file: file, line: line)
      XCTAssertEqual(store.allowsAccess(.camera), true, file: file, line: line)
      XCTAssertEqual(firstObserverPublications, 0, file: file, line: line)
      XCTAssertEqual(secondObserverPublications, 0, file: file, line: line)

      // A subsequent host action still updates state and notifies both observers once.
      await checker.setResult(.supported(.denied))
      try await store.refresh(.camera)
      XCTAssertEqual(store.status(for: .camera), .supported(.denied), file: file, line: line)
      XCTAssertEqual(firstObserverPublications, 1, file: file, line: line)
      XCTAssertEqual(secondObserverPublications, 1, file: file, line: line)
      withExtendedLifetime((firstSubscription, secondSubscription)) {}
    }
  }
}

private actor CancellationTestChecker: PermissionChecking {
  enum Operation: Hashable, Sendable {
    case status(PermissionType)
    case request(PermissionType)
  }

  private(set) var calls: [Operation] = []
  private var result: PermissionOperationResult<PermissionStatus> = .supported(.limited)
  private var suspendedOperations: Set<Operation> = []
  private var pending:
    [Operation: CheckedContinuation<PermissionOperationResult<PermissionStatus>, Never>] = [:]
  private var waiters: [Operation: [CheckedContinuation<Void, Never>]] = [:]

  func suspendNext(_ operation: Operation) {
    suspendedOperations.insert(operation)
  }

  func setResult(_ result: PermissionOperationResult<PermissionStatus>) {
    self.result = result
  }

  func status(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    await perform(.status(type))
  }

  func requestAccess(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    await perform(.request(type))
  }

  nonisolated func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    XCTFail("The store must not open System Settings")
    return .supported(false)
  }

  func waitForCall(_ operation: Operation) async {
    if pending[operation] != nil { return }
    await withCheckedContinuation { waiters[operation, default: []].append($0) }
  }

  func finish(_ operation: Operation, with result: PermissionOperationResult<PermissionStatus>) {
    pending.removeValue(forKey: operation)?.resume(returning: result)
  }

  private func perform(_ operation: Operation) async -> PermissionOperationResult<PermissionStatus>
  {
    calls.append(operation)
    guard suspendedOperations.remove(operation) != nil else { return result }
    return await withCheckedContinuation { continuation in
      pending[operation] = continuation
      for waiter in waiters.removeValue(forKey: operation) ?? [] { waiter.resume() }
    }
  }
}
