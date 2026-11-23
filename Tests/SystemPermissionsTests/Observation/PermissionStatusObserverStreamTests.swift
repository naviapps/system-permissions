import SystemPermissions
import XCTest

final class PermissionStatusObserverStreamTests: XCTestCase {
  func testUpdateValueIsAvailableFromPublicImport() {
    let update = PermissionStatusObserver.Update(type: .camera, result: .supported(.granted))
    func requireSendable<Value: Sendable>(_: Value) {}
    requireSendable(update)
    XCTAssertEqual(update.type, .camera)
    XCTAssertEqual(update.result, .supported(.granted))
    XCTAssertEqual(Set([update, update]).count, 1)
  }

  func testUpdatesFinishImmediatelyForEmptyTypes() async {
    var iterator = PermissionStatusObserver.updates(
      for: [], using: SequenceChecker(sequences: [:])
    ).makeAsyncIterator()
    let update = await iterator.next()
    XCTAssertNil(update)
  }

  func testUpdatesReturnAnInitialFailure() async {
    let checker = SequenceChecker(sequences: [.camera: [.failed(.apiUnavailable)]])
    let stream = PermissionStatusObserver.updates(for: [.camera], using: checker)

    let updates = await collect(stream, count: 1)

    XCTAssertEqual(updates, [.init(type: .camera, result: .failed(.apiUnavailable))])
  }

  func testLongPollingIntervalStaysCancellable() async {
    let checker = SequenceChecker(sequences: [.camera: [.supported(.granted)]])
    let initial = expectation(description: "delivers the initial sample")
    let earlyResult = expectation(description: "does not finish or emit a second sample early")
    earlyResult.isInverted = true
    let terminated = expectation(description: "cancellation ends the pending wait")
    let consumer = Task {
      var iterator = PermissionStatusObserver.updates(
        for: [.camera], using: checker, pollingInterval: .seconds(60 * 24 * 60 * 60)
      ).makeAsyncIterator()
      if let sample = await iterator.next() {
        XCTAssertEqual(sample, .init(type: .camera, result: .supported(.granted)))
        initial.fulfill()
      }
      let next = await iterator.next()
      if next != nil || !Task.isCancelled { earlyResult.fulfill() }
      terminated.fulfill()
    }
    await fulfillment(of: [initial], timeout: 2)
    await fulfillment(of: [earlyResult], timeout: 0.25)
    consumer.cancel()
    await fulfillment(of: [terminated], timeout: 2)
    XCTAssertEqual(checker.observedOptions(for: .camera).count, 1)
  }

  func testMalformedProviderResultStopsUpdatesWithoutPublishingIt() async throws {
    let checker = SequenceChecker(sequences: [
      .camera: [.supported(.granted)],
      .microphone: [try malformedResult()],
    ])
    let stream = PermissionStatusObserver.updates(
      for: [.camera, .microphone, .contacts], using: checker)

    let updates = await collect(stream, count: 2)

    XCTAssertEqual(updates, [.init(type: .camera, result: .supported(.granted))])
    XCTAssertEqual(checker.observedOptions(for: .microphone).count, 1)
    XCTAssertTrue(checker.observedOptions(for: .contacts).isEmpty)
  }

  func testMalformedProviderResultStopsChangesWithoutReplacingTheLastValidResult() async throws {
    let checker = SequenceChecker(sequences: [
      .camera: [.supported(.granted), .supported(.denied), try malformedResult()]
    ])
    let stream = PermissionStatusObserver.changes(
      for: [.camera], using: checker, pollingInterval: .milliseconds(250))

    let changes = await collect(stream, count: 2)

    XCTAssertEqual(
      changes,
      [
        .init(
          type: .camera, previousResult: .supported(.granted), currentResult: .supported(.denied))
      ])
    XCTAssertEqual(checker.observedOptions(for: .camera).count, 3)
  }

  func testUpdatesRejectTheWholeListBeforePollingWhenAnAutomationTargetIsInvalid() async {
    let valid = PermissionType.automation(targetApplication: "com.example.Keyboard")
    let invalid = PermissionType.automation(targetApplication: "com.example.\u{212A}eyboard")
    let checker = SequenceChecker(sequences: [valid: [.supported(.granted)]])
    let stream = PermissionStatusObserver.updates(
      for: [valid, invalid], using: checker,
      options: { _ in
        XCTFail("An invalid descriptor list must not invoke the options provider")
        return .none
      })

    let updates = await collect(stream, count: 1)

    XCTAssertTrue(updates.isEmpty)
    XCTAssertTrue(checker.observedOptions(for: valid).isEmpty)
  }

  func testChangesRejectConflictingDescriptorMetadataBeforePolling() async throws {
    let id = "com.example.status"
    let permission = PermissionType.custom(
      try CustomPermission(
        identifier: id,
        capability: .init(
          supportsStatusCheck: true, supportsRequest: true, systemSettingsURL: nil,
          requiresRelaunch: false)))
    let conflicting = PermissionType.custom(
      try CustomPermission(
        identifier: id,
        capability: .init(
          supportsStatusCheck: true, supportsRequest: false, systemSettingsURL: nil,
          requiresRelaunch: false)))
    let checker = SequenceChecker(
      sequences: [permission: [.supported(.denied), .supported(.granted)]])
    let stream = PermissionStatusObserver.changes(
      for: [permission, conflicting], using: checker, pollingInterval: .milliseconds(250),
      options: { _ in
        XCTFail("Conflicting descriptor metadata must not invoke the options provider")
        return .none
      })

    let changes = await collect(stream, count: 1)

    XCTAssertTrue(changes.isEmpty)
    XCTAssertTrue(checker.observedOptions(for: permission).isEmpty)
  }

  func testThrowingObservationReportsDescriptorErrorsBeforePolling() async throws {
    let valid = PermissionType.automation(targetApplication: "com.example.Keyboard")
    let invalid = PermissionType.automation(targetApplication: "com.example.\u{212A}eyboard")
    let id = "com.example.status"
    let custom = PermissionType.custom(
      try CustomPermission(
        identifier: id,
        capability: .init(
          supportsStatusCheck: true, supportsRequest: true, systemSettingsURL: nil,
          requiresRelaunch: false)))
    let conflicting = PermissionType.custom(
      try CustomPermission(
        identifier: id,
        capability: .init(
          supportsStatusCheck: true, supportsRequest: false, systemSettingsURL: nil,
          requiresRelaunch: false)))
    let checker = SequenceChecker(sequences: [:])
    let options: @Sendable (PermissionType) -> PermissionOptions = { _ in
      XCTFail("An invalid descriptor list must not invoke the options provider")
      return .none
    }

    let updates = await collectTermination(
      PermissionStatusObserver.throwingUpdates(
        for: [valid, invalid], using: checker, options: options)
    )
    let changes = await collectTermination(
      PermissionStatusObserver.throwingChanges(
        for: [custom, conflicting], using: checker, options: options))
    let oversized = await collectTermination(
      PermissionStatusObserver.throwingUpdates(
        for: Array(repeating: .camera, count: 1_025), using: checker, options: options))

    XCTAssertTrue(updates.events.isEmpty)
    XCTAssertEqual(updates.errorCode, "invalidTargetApplication")
    XCTAssertTrue(changes.events.isEmpty)
    XCTAssertEqual(changes.errorCode, "inconsistentMetadata")
    XCTAssertTrue(oversized.events.isEmpty)
    XCTAssertEqual(oversized.errorCode, "limitExceeded")
    XCTAssertTrue(checker.observedOptions(for: valid).isEmpty)
    XCTAssertTrue(checker.observedOptions(for: custom).isEmpty)
    XCTAssertTrue(checker.observedOptions(for: .camera).isEmpty)
  }

  func testThrowingUpdatesDeliverBufferedSampleBeforeResultError() async throws {
    let checked = expectation(description: "invalid check starts after valid sample is buffered")
    let checker = SequenceChecker(
      sequences: [.camera: [.supported(.granted)], .microphone: [try malformedResult()]],
      onCheck: { type, _ in
        if type == .microphone { checked.fulfill() }
      })
    let stream = PermissionStatusObserver.throwingUpdates(
      for: [.camera, .camera, .microphone, .contacts], using: checker)

    await fulfillment(of: [checked], timeout: 2)
    let result = await collectTermination(stream)

    XCTAssertEqual(result.events, [.init(type: .camera, result: .supported(.granted))])
    XCTAssertEqual(result.errorCode, "invalidResult")
    XCTAssertEqual(checker.observedOptions(for: .camera).count, 1)
    XCTAssertEqual(checker.observedOptions(for: .microphone).count, 1)
    XCTAssertTrue(checker.observedOptions(for: .contacts).isEmpty)
  }

  func testThrowingChangesKeepNewestBufferedTransitionBeforeResultError() async throws {
    let checked = expectation(description: "invalid check starts after two transitions")
    let checker = SequenceChecker(
      sequences: [
        .photos: [
          .supported(.granted), .supported(.denied), .supported(.granted), try malformedResult(),
        ]
      ],
      onCheck: { _, count in
        if count == 4 { checked.fulfill() }
      })
    let stream = PermissionStatusObserver.throwingChanges(
      for: [.photos, .photos], using: checker, pollingInterval: .milliseconds(10),
      options: { _ in .photos(.addOnly) })

    await fulfillment(of: [checked], timeout: 2)
    let result = await collectTermination(stream)

    XCTAssertEqual(
      result.events,
      [
        .init(
          type: .photos, previousResult: .supported(.denied), currentResult: .supported(.granted))
      ])
    XCTAssertEqual(result.errorCode, "invalidResult")
    XCTAssertEqual(
      checker.observedOptions(for: .photos), Array(repeating: .photos(.addOnly), count: 4))
  }

  func testUpdatesCoalesceBacklogAndRepeatTheLatestStableResult() async {
    let results: [PermissionOperationResult<PermissionStatus>] = [
      .supported(.denied), .supported(.denied), .failed(.apiUnavailable),
      .unsupported(PermissionType.photos.capability),
    ]
    let checked = expectation(description: "fifth check is suspended after four buffered samples")
    let gate = SampleCheckGate()
    let checker = SequenceChecker(
      sequences: [.photos: results],
      onCheck: { _, count in
        if count == 5 {
          checked.fulfill()
          await gate.wait()
        }
      })
    let stream = PermissionStatusObserver.updates(
      for: [.photos, .photos], using: checker, pollingInterval: .milliseconds(10),
      options: { _ in .photos(.addOnly) })

    await fulfillment(of: [checked], timeout: 2)
    let received = expectation(description: "latest buffered sample and its stable repeat")
    let consumer = Task {
      var iterator = stream.makeAsyncIterator()
      let latest = await iterator.next()
      XCTAssertEqual(latest, .init(type: .photos, result: results.last!))
      await gate.release()
      let repeated = await iterator.next()
      XCTAssertEqual(repeated, latest)
      received.fulfill()
    }
    await fulfillment(of: [received], timeout: 2)
    consumer.cancel()
    await gate.release()
    await consumer.value
    XCTAssertTrue(checker.observedOptions(for: .photos).allSatisfy { $0 == .photos(.addOnly) })
  }

  func testUpdatesDeduplicateTypesAndUsePermissionDefaultOptions() async {
    let checker = SequenceChecker(sequences: [
      .photos: [.supported(.granted)], .notifications: [.supported(.denied)],
    ])
    let stream = PermissionStatusObserver.updates(
      for: [.photos, .photos, .notifications], using: checker)
    let updates = await collect(stream, count: 2)

    XCTAssertEqual(
      updates,
      [
        .init(type: .photos, result: .supported(.granted)),
        .init(type: .notifications, result: .supported(.denied)),
      ])
    XCTAssertTrue(checker.observedOptions(for: .photos).allSatisfy { $0 == .photos(.default) })
    XCTAssertTrue(
      checker.observedOptions(for: .notifications).allSatisfy { $0 == .notifications(.default) })
  }

  func testAlreadyCancelledUpdatesDoNotStartChecks() async {
    let checker = SequenceChecker(sequences: [.camera: [.supported(.granted)]])
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      for await _ in PermissionStatusObserver.updates(for: [.camera], using: checker) {
        XCTFail("An already cancelled observer must not publish a sample")
      }
    }
    await task.value
    XCTAssertTrue(checker.observedOptions(for: .camera).isEmpty)
  }

  func testChangesStillSkipInitialAndRepeatedSamples() async {
    let checker = SequenceChecker(sequences: [
      .camera: [
        .supported(.denied), .supported(.denied), .supported(.granted),
        .supported(.granted), .supported(.denied),
      ]
    ])
    let stream = PermissionStatusObserver.changes(
      for: [.camera], using: checker, pollingInterval: .milliseconds(10))
    let changes = await collect(stream, count: 2)

    XCTAssertEqual(
      changes,
      [
        .init(
          type: .camera, previousResult: .supported(.denied), currentResult: .supported(.granted)),
        .init(
          type: .camera, previousResult: .supported(.granted), currentResult: .supported(.denied)),
      ])
  }

  func testStreamFinishesImmediatelyForEmptyTypes() async {
    let stream = PermissionStatusObserver.changes(
      for: [],
      using: SequenceChecker(sequences: [:])
    )

    var iterator = stream.makeAsyncIterator()
    let change = await iterator.next()
    XCTAssertNil(change)
  }

  func testStreamDeduplicatesTypes() async {
    let checker = SequenceChecker(
      sequences: [
        .contacts: [.supported(.denied), .supported(.granted)]
      ]
    )
    let stream = PermissionStatusObserver.changes(
      for: [.contacts, .contacts],
      using: checker,
      pollingInterval: .milliseconds(10)
    )

    let firstChange = expectation(description: "received first change")

    let task = Task {
      for await change in stream where change.type == .contacts {
        XCTAssertEqual(change.previousResult, .supported(.denied))
        XCTAssertEqual(change.currentResult, .supported(.granted))
        firstChange.fulfill()
        break
      }
    }

    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(checker.observedOptions(for: .contacts).count, 1)

    await fulfillment(of: [firstChange], timeout: 1.0)
    task.cancel()
  }

  func testStreamUsesCustomOptions() async {
    let checker = SequenceChecker(
      sequences: [
        .photos: [.supported(.denied), .supported(.granted)]
      ]
    )
    let stream = PermissionStatusObserver.changes(
      for: [.photos],
      using: checker,
      pollingInterval: .milliseconds(10),
      options: { type in
        type == .photos ? .photos(.addOnly) : .none
      }
    )

    let exp = expectation(description: "received change")
    let task = Task {
      for await change in stream where change.type == .photos {
        XCTAssertEqual(change.previousResult, .supported(.denied))
        XCTAssertEqual(change.currentResult, .supported(.granted))
        exp.fulfill()
        break
      }
    }

    await fulfillment(of: [exp], timeout: 1.0)
    task.cancel()
    let options = checker.observedOptions(for: .photos)
    XCTAssertGreaterThanOrEqual(options.count, 2)
    XCTAssertTrue(options.allSatisfy { $0 == .photos(.addOnly) })
  }

  func testStreamUsesPermissionDefaultOptionsWhenProviderIsOmitted() async {
    let checker = SequenceChecker(
      sequences: [
        .photos: [.supported(.denied), .supported(.granted)],
        .notifications: [.supported(.notDetermined), .supported(.granted)],
      ]
    )
    let stream = PermissionStatusObserver.changes(
      for: [.photos, .notifications],
      using: checker,
      pollingInterval: .milliseconds(10)
    )

    let exp = expectation(description: "received changes")
    exp.expectedFulfillmentCount = 2
    let task = Task {
      var received: Set<PermissionType> = []
      for await change in stream {
        received.insert(change.type)
        exp.fulfill()
        if received.count == 2 { break }
      }
    }

    await fulfillment(of: [exp], timeout: 1.0)
    task.cancel()

    XCTAssertGreaterThanOrEqual(checker.observedOptions(for: .photos).count, 2)
    XCTAssertGreaterThanOrEqual(checker.observedOptions(for: .notifications).count, 2)
    XCTAssertTrue(checker.observedOptions(for: .photos).allSatisfy { $0 == .photos(.default) })
    XCTAssertTrue(
      checker.observedOptions(for: .notifications).allSatisfy { $0 == .notifications(.default) })
  }

  private func malformedResult() throws -> PermissionOperationResult<PermissionStatus> {
    .unsupported(
      .init(
        supportsStatusCheck: false, supportsRequest: false,
        systemSettingsURL: try XCTUnwrap(URL(string: "relative/path")), requiresRelaunch: false))
  }

  private func collect<Event: Sendable>(_ stream: AsyncStream<Event>, count: Int) async -> [Event] {
    let finished = expectation(description: "received \(count) events")
    let consumer = Task {
      var events: [Event] = []
      for await event in stream {
        events.append(event)
        if events.count == count { break }
      }
      finished.fulfill()
      return events
    }
    await fulfillment(of: [finished], timeout: 2)
    consumer.cancel()
    return await consumer.value
  }

  private func collectTermination<Event: Sendable>(
    _ stream: AsyncThrowingStream<Event, any Error>
  ) async -> (events: [Event], errorCode: String?) {
    let finished = expectation(description: "reached throwing stream termination")
    let consumer = Task {
      defer { finished.fulfill() }
      var events: [Event] = []
      do {
        for try await event in stream { events.append(event) }
        return (events, nil as String?)
      } catch let error as PermissionContractError {
        return (events, error.code)
      } catch {
        XCTFail("Expected a permission contract error, received \(error)")
        return (events, nil)
      }
    }
    await fulfillment(of: [finished], timeout: 2)
    consumer.cancel()
    return await consumer.value
  }
}

private final class SequenceChecker: PermissionStatusChecking, @unchecked Sendable {
  private let lock = NSLock()
  private var sequences: [PermissionType: [PermissionOperationResult<PermissionStatus>]]
  private var indices: [PermissionType: Int] = [:]
  private var options: [PermissionType: [PermissionOptions]] = [:]
  private let onCheck: @Sendable (PermissionType, Int) async -> Void

  init(
    sequences: [PermissionType: [PermissionOperationResult<PermissionStatus>]],
    onCheck: @escaping @Sendable (PermissionType, Int) async -> Void = { _, _ in }
  ) {
    self.sequences = sequences
    self.onCheck = onCheck
  }

  func status(for type: PermissionType, options permissionOptions: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    let (value, count) = lock.withLock {
      options[type, default: []].append(permissionOptions)
      let values = sequences[type] ?? [.supported(.unknown)]
      let index = indices[type, default: 0]
      let value = values[min(index, values.count - 1)]
      indices[type] = index + 1
      return (value, index + 1)
    }
    await onCheck(type, count)
    return value
  }

  func observedOptions(for type: PermissionType) -> [PermissionOptions] {
    lock.withLock {
      options[type, default: []]
    }
  }
}

private actor SampleCheckGate {
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
