import SystemPermissions
import XCTest

final class PermissionCheckerCancellationTests: XCTestCase {
  func testCancellationDuringDirectStatusDiscardsProviderGrant() async {
    await assertCancellationDiscardsProviderGrant(requestAccess: false)
  }

  func testCancellationDuringDirectRequestDiscardsProviderGrant() async {
    await assertCancellationDiscardsProviderGrant(requestAccess: true)
  }

  func testAlreadyCancelledDirectRequestDoesNotInvokeProvider() async {
    let checker = PermissionChecker(
      environment: .init(
        status: { _, _ in
          XCTFail("Cancelled status must not call a provider")
          return .supported(.granted)
        },
        requestAccess: { _, _ in
          XCTFail("Cancelled request must not call a provider")
          return .supported(.granted)
        },
        openURL: { _ in
          XCTFail("No Settings effect expected")
          return false
        }))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let status = await checker.status(for: .camera)
      let requested = await checker.requestAccess(for: .camera)
      XCTAssertEqual(status, .supported(.unknown))
      XCTAssertEqual(requested, .supported(.unknown))
    }
    await task.value
  }

  private func assertCancellationDiscardsProviderGrant(
    requestAccess: Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let started = expectation(description: "provider is suspended")
    let provider = SuspendedPermissionResult(started: started)
    let checker = PermissionChecker(
      environment: .init(
        status: { _, _ in await provider.result() },
        requestAccess: { _, _ in await provider.result() },
        openURL: { _ in
          XCTFail("No Settings effect expected")
          return false
        }))
    let task = Task {
      if requestAccess { return await checker.requestAccess(for: .camera) }
      return await checker.status(for: .camera)
    }

    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    // Simulate an OS provider that cannot stop the already-started operation.
    await provider.finish()
    let result = await task.value
    XCTAssertEqual(result, .supported(.unknown), file: file, line: line)
  }
}

private actor SuspendedPermissionResult {
  private let started: XCTestExpectation
  private var continuation: CheckedContinuation<PermissionOperationResult<PermissionStatus>, Never>?

  init(started: XCTestExpectation) { self.started = started }

  func result() async -> PermissionOperationResult<PermissionStatus> {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started.fulfill()
    }
  }

  func finish() {
    continuation?.resume(returning: .supported(.granted))
    continuation = nil
  }
}
