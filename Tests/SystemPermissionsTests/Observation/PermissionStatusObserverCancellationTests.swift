import Foundation
import SystemPermissions
import XCTest

final class PermissionStatusObserverCancellationTests: XCTestCase {
  func testCancellationDuringInitialCheckStopsRemainingPermissions() async {
    await assertCancellationStopsAfterCamera(round: 1)
  }

  func testCancellationDuringLaterPollStopsRemainingPermissions() async {
    await assertCancellationStopsAfterCamera(round: 2)
  }

  func testUpdatesCancellationDuringInitialCheckStopsRemainingPermissions() async {
    await assertCancellationStopsAfterCamera(round: 1, updates: true)
  }

  func testUpdatesCancellationDuringLaterPollStopsRemainingPermissions() async {
    await assertCancellationStopsAfterCamera(round: 2, updates: true)
  }

  func testThrowingUpdatesCancellationDiscardsAnOutstandingCheck() async {
    let started = expectation(description: "camera check is suspended")
    let finished = expectation(description: "consumer finishes before the provider responds")
    let released = expectation(description: "producer releases its checker")
    let trace = CheckTrace()
    var checker: SuspendedChecker? = SuspendedChecker(
      suspendedRound: 1, trace: trace, started: started, released: released)
    var consumer: Task<Void, Never>? = Task { [checker = checker!] in
      defer { finished.fulfill() }
      do {
        for try await update in PermissionStatusObserver.throwingUpdates(
          for: [.camera, .microphone], using: checker
        ) {
          trace.recordDelivery(update.type)
        }
      } catch {
        XCTFail("Consumer cancellation must finish observation without a contract error: \(error)")
      }
    }

    await fulfillment(of: [started], timeout: 2)
    consumer?.cancel()
    await fulfillment(of: [finished], timeout: 2)
    checker?.resume()
    checker = nil
    await consumer?.value
    consumer = nil
    await fulfillment(of: [released], timeout: 2)

    XCTAssertEqual(trace.checkedTypes, [.camera])
    XCTAssertTrue(trace.deliveredTypes.isEmpty)
  }

  func testCancellationDuringOptionsStopsStatusDispatch() async {
    for updates in [true, false] {
      let trace = CheckTrace()
      let checker = RecordingStatusChecker(trace: trace)
      let options: @Sendable (PermissionType) -> PermissionOptions = { type in
        trace.recordOptions(type)
        withUnsafeCurrentTask { $0?.cancel() }
        return .none
      }

      if updates {
        var iterator = PermissionStatusObserver.updates(
          for: [.camera, .microphone], using: checker, options: options
        ).makeAsyncIterator()
        let result = await iterator.next()
        XCTAssertNil(result)
      } else {
        var iterator = PermissionStatusObserver.changes(
          for: [.camera, .microphone], using: checker, options: options
        ).makeAsyncIterator()
        let result = await iterator.next()
        XCTAssertNil(result)
      }

      XCTAssertEqual(trace.optionTypes, [.camera])
      XCTAssertTrue(trace.checkedTypes.isEmpty)
    }
  }

  private func assertCancellationStopsAfterCamera(
    round: Int, updates: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let started = expectation(description: "camera check is suspended")
    let released = expectation(description: "producer releases its checker")
    let trace = CheckTrace()
    var checker: SuspendedChecker? = SuspendedChecker(
      suspendedRound: round, trace: trace, started: started, released: released)
    var consumer: Task<Void, Never>? = Task { [checker = checker!] in
      let options: @Sendable (PermissionType) -> PermissionOptions = { type in
        trace.recordOptions(type)
        return type.defaultOptions
      }
      if updates {
        for await update in PermissionStatusObserver.updates(
          for: [.camera, .microphone], using: checker,
          pollingInterval: .milliseconds(250), options: options
        ) {
          trace.recordDelivery(update.type)
        }
      } else {
        for await change in PermissionStatusObserver.changes(
          for: [.camera, .microphone], using: checker,
          pollingInterval: .milliseconds(250), options: options
        ) {
          trace.recordDelivery(change.type)
        }
      }
    }

    await fulfillment(of: [started], timeout: 2)
    consumer?.cancel()
    await consumer?.value
    consumer = nil

    // The provider intentionally ignores task cancellation until explicitly resumed.
    checker?.resume()
    checker = nil
    await fulfillment(of: [released], timeout: 2)

    let expected =
      Array(repeating: [PermissionType.camera, .microphone], count: round - 1)
      .flatMap { $0 } + [.camera]
    XCTAssertEqual(trace.checkedTypes, expected, file: file, line: line)
    XCTAssertEqual(trace.optionTypes, expected, file: file, line: line)
    // Earlier samples may still be buffered when cancellation reaches the consumer.
    let earlierSamples: [PermissionType] = updates && round == 2 ? [.camera, .microphone] : []
    let delivered = trace.deliveredTypes
    XCTAssertEqual(delivered, Array(earlierSamples.prefix(delivered.count)), file: file, line: line)
  }
}

private struct RecordingStatusChecker: PermissionStatusChecking {
  let trace: CheckTrace

  func status(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    _ = trace.recordCheck(type)
    return .supported(.denied)
  }
}

private final class CheckTrace: @unchecked Sendable {
  private let lock = NSLock()
  private var checks: [PermissionType] = []
  private var options: [PermissionType] = []
  private var delivered: [PermissionType] = []

  func recordCheck(_ type: PermissionType) -> Int {
    lock.withLock {
      checks.append(type)
      return checks.filter { $0 == type }.count
    }
  }

  func recordOptions(_ type: PermissionType) {
    lock.withLock { options.append(type) }
  }

  func recordDelivery(_ type: PermissionType) {
    lock.withLock { delivered.append(type) }
  }

  var checkedTypes: [PermissionType] { lock.withLock { checks } }
  var optionTypes: [PermissionType] { lock.withLock { options } }
  var deliveredTypes: [PermissionType] { lock.withLock { delivered } }
}

private final class SuspendedChecker: PermissionStatusChecking, @unchecked Sendable {
  private let suspendedRound: Int
  private let trace: CheckTrace
  private let started: XCTestExpectation
  private let released: XCTestExpectation
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?

  init(
    suspendedRound: Int, trace: CheckTrace,
    started: XCTestExpectation, released: XCTestExpectation
  ) {
    self.suspendedRound = suspendedRound
    self.trace = trace
    self.started = started
    self.released = released
  }

  deinit { released.fulfill() }

  func status(for type: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    let round = trace.recordCheck(type)
    if type == .camera && round == suspendedRound {
      await withCheckedContinuation { continuation in
        lock.withLock { self.continuation = continuation }
        started.fulfill()
      }
    }
    return .supported(.denied)
  }

  func resume() {
    let pending = lock.withLock {
      let pending = continuation
      continuation = nil
      return pending
    }
    pending?.resume()
  }
}
