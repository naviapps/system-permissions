import SystemPermissions
import UserNotifications
import XCTest

@testable import SystemPermissionsMacOS

final class PermissionEnvironmentLiveTests: XCTestCase {
  func testLiveStatusClosureReturnsResultsForCLISafeTypes() async throws {
    let checker = PermissionChecker()
    let results = await [
      checker.status(for: .accessibility),
      checker.status(for: .screenRecording),
      checker.status(for: .camera),
      checker.status(for: .microphone),
      checker.status(for: .speechRecognition),
      checker.status(for: .notifications),
    ]

    XCTAssertEqual(results.count, 6)
    for result in results {
      switch result {
      case .supported(let status):
        switch status {
        case .granted, .limited, .provisional, .ephemeral, .denied, .restricted, .notDetermined,
          .unknown:
          break
        }
      case .failed(.apiUnavailable):
        break
      case .failed, .unsupported:
        XCTFail("Unexpected live status result: \(result)")
      }
    }
  }

  func testNotificationRequestUsesTheStatusObservedAfterAuthorization() async {
    let cases: [(Bool, UNAuthorizationStatus, PermissionStatus)] = [
      (true, .provisional, .provisional),
      (true, .authorized, .granted),
      (false, .denied, .denied),
      (false, .notDetermined, .notDetermined),
    ]
    for (granted, status, expected) in cases {
      let center = NotificationCenterFixture(
        initial: .notDetermined, settled: status, completion: .success(granted))
      let result = await requestNotificationAccess(
        options: [.alert, .provisional], status: { await center.status() },
        request: { try await center.request($0) })
      let readCount = await center.readCount
      let requests = await center.requests
      XCTAssertEqual(result, .supported(expected))
      XCTAssertEqual(readCount, 2)
      XCTAssertEqual(requests, [[.alert, .provisional]])
    }
  }

  func testNotificationRequestKeepsExistingAuthorizationWithoutPrompting() async {
    let cases: [(UNAuthorizationStatus, PermissionStatus)] = [
      (.authorized, .granted), (.provisional, .provisional), (.denied, .denied),
    ]
    for (status, expected) in cases {
      let center = NotificationCenterFixture(
        initial: status, settled: .notDetermined, completion: .failure(.unavailable))
      let result = await requestNotificationAccess(
        options: .default, status: { await center.status() },
        request: { try await center.request($0) })
      let readCount = await center.readCount
      let requests = await center.requests
      XCTAssertEqual(result, .supported(expected))
      XCTAssertEqual(readCount, 1)
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testNotificationRequestReportsFrameworkFailureWithoutReadingSettingsAgain() async {
    let center = NotificationCenterFixture(
      initial: .notDetermined, settled: .authorized, completion: .failure(.unavailable))
    let result = await requestNotificationAccess(
      options: .alert, status: { await center.status() },
      request: { try await center.request($0) })
    let readCount = await center.readCount
    let requests = await center.requests
    XCTAssertEqual(result, .failed(.apiUnavailable))
    XCTAssertEqual(readCount, 1)
    XCTAssertEqual(requests, [.alert])
  }
}

private actor NotificationCenterFixture {
  enum Failure: Error { case unavailable }

  private let initial: UNAuthorizationStatus
  private let settled: UNAuthorizationStatus
  private let completion: Result<Bool, Failure>
  private(set) var readCount = 0
  private(set) var requests: [UNAuthorizationOptions] = []

  init(
    initial: UNAuthorizationStatus, settled: UNAuthorizationStatus,
    completion: Result<Bool, Failure>
  ) {
    self.initial = initial
    self.settled = settled
    self.completion = completion
  }

  func status() -> UNAuthorizationStatus {
    readCount += 1
    return readCount == 1 ? initial : settled
  }

  func request(_ options: UNAuthorizationOptions) throws -> Bool {
    requests.append(options)
    return try completion.get()
  }
}
