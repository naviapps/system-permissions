import SystemPermissions
import XCTest

final class PermissionCheckingTests: XCTestCase {
  func testStatusOverloadUsesDefaultOptions() async {
    let checker = RecordingPermissionChecker()
    let statusChecker: any PermissionStatusChecking = checker
    XCTAssertEqual(statusChecker.platform, .macOS)

    _ = await statusChecker.status(for: .notifications)
    _ = await statusChecker.status(for: .photos)
    _ = await statusChecker.status(for: .camera)

    XCTAssertEqual(
      checker.observedOptions,
      [
        .notifications(.default),
        .photos(.default),
        .none,
      ]
    )
  }

  func testRequestAccessOverloadUsesDefaultOptions() async {
    let checker = RecordingPermissionChecker()

    _ = await checker.requestAccess(for: .notifications)
    _ = await checker.requestAccess(for: .photos)
    _ = await checker.requestAccess(for: .camera)

    XCTAssertEqual(
      checker.permissionOptions,
      [
        .notifications(.default),
        .photos(.default),
        .none,
      ]
    )
  }

  func testInjectedWindowsCheckerUsesItsPlatformContractForAllEffects() async throws {
    let checker: any PermissionChecking = PermissionChecker(
      environment: .init(
        platform: .windows,
        status: { type, options in
          XCTAssertEqual(type, .location)
          XCTAssertEqual(options, .none)
          return .supported(.restricted)
        },
        requestAccess: { type, options in
          XCTAssertEqual(type, .location)
          XCTAssertEqual(options, .none)
          return .supported(.granted)
        },
        openURL: { url in
          XCTAssertEqual(url.scheme, "ms-settings")
          return true
        }))
    XCTAssertEqual(checker.platform, .windows)

    let status = await checker.status(for: .location)
    let request = await checker.requestAccess(for: .location)
    XCTAssertEqual(status, .supported(.restricted))
    XCTAssertEqual(request, .supported(.granted))
    XCTAssertEqual(checker.openSystemSettings(for: .location), .supported(true))

    let capability = try PermissionType.accessibility.metadata(on: .windows).capability
    let unsupportedStatus = await checker.status(for: .accessibility)
    let unsupportedRequest = await checker.requestAccess(for: .accessibility)
    XCTAssertEqual(unsupportedStatus, .unsupported(capability))
    XCTAssertEqual(unsupportedRequest, .unsupported(capability))
    XCTAssertEqual(checker.openSystemSettings(for: .accessibility), .unsupported(capability))

    let stream = PermissionStatusObserver.updates(for: [.location], using: checker)
    var iterator = stream.makeAsyncIterator()
    let observed = await iterator.next()
    XCTAssertEqual(observed, .init(type: .location, result: .supported(.restricted)))
  }
}

private final class RecordingPermissionChecker: PermissionChecking, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var observedOptions: [PermissionOptions] = []
  private(set) var permissionOptions: [PermissionOptions] = []

  func status(for _: PermissionType, options: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    lock.withLock {
      observedOptions.append(options)
    }
    return .supported(.granted)
  }

  func requestAccess(for _: PermissionType, options: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    lock.withLock {
      permissionOptions.append(options)
    }
    return .supported(.granted)
  }

  func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    .supported(true)
  }
}
