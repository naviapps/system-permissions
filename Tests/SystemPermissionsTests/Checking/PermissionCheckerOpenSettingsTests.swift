import SystemPermissions
import XCTest

final class PermissionCheckerOpenSettingsTests: XCTestCase {
  func testOpenSystemSettingsReturnsUnsupportedWhenURLMissing() throws {
    let capability = PermissionCapability(
      supportsStatusCheck: false,
      supportsRequest: false,
      systemSettingsURL: nil,
      requiresRelaunch: false
    )
    let type = PermissionType.custom(
      try CustomPermission(identifier: "custom.permission", capability: capability)
    )
    let checker = PermissionChecker(environment: makeEnvironment(openURL: { _ in true }))

    let result = checker.openSystemSettings(for: type)
    XCTAssertEqual(result, .unsupported(capability))
  }

  func testOpenSystemSettingsReturnsOpenedWhenOpenURLSucceeds() {
    let checker = PermissionChecker(environment: makeEnvironment(openURL: { _ in true }))
    let result = checker.openSystemSettings(for: .accessibility)
    XCTAssertEqual(result, .supported(true))
  }

  func testOpenSystemSettingsReturnsOpenFailedWhenOpenURLFails() {
    let checker = PermissionChecker(environment: makeEnvironment(openURL: { _ in false }))

    let result = checker.openSystemSettings(for: .accessibility)

    XCTAssertEqual(result, .failed(.openFailed))
  }

  func testExplicitOptionsRejectInvalidAndUnavailableRequestsWithoutEffects() async throws {
    let checker = PermissionChecker(
      environment: makeEnvironment(platform: .windows) { _ in
        XCTFail("Rejected Settings requests must not invoke the environment")
        return false
      })

    let invalid = try await checker.openSystemSettings(for: .camera, options: .photos(.addOnly))
    XCTAssertEqual(invalid, .failed(.invalidOptions))
    let unavailable = try await checker.openSystemSettings(for: .accessibility, options: .none)
    XCTAssertEqual(
      unavailable, .unsupported(try PermissionType.accessibility.metadata(on: .windows).capability))
    do {
      _ = try await checker.openSystemSettings(
        for: .automation(targetApplication: "unscoped"), options: .none)
      XCTFail("Invalid descriptors must throw a contract error")
    } catch let error as PermissionContractError {
      XCTAssertEqual(error.code, "invalidTargetApplication")
    }
  }

  func testExplicitOptionsDispatchTheSelectedPlatformDestination() async throws {
    let checker: any PermissionChecking = PermissionChecker(
      environment: makeEnvironment(platform: .windows) { destination in
        XCTAssertEqual(destination.absoluteString, "ms-settings:privacy-webcam")
        return false
      })
    let result = try await checker.openSystemSettings(for: .camera, options: .none)
    XCTAssertEqual(result, .failed(.openFailed))
  }

  func testExplicitOptionsThrowWhenCancelledBeforeOrDuringTheEffect() async throws {
    for alreadyCancelled in [false, true] {
      let checker = PermissionChecker(
        environment: makeEnvironment { _ in
          XCTAssertFalse(alreadyCancelled, "An already-cancelled call must not open Settings")
          withUnsafeCurrentTask { $0?.cancel() }
          return true
        })
      let task = Task {
        if alreadyCancelled {
          withUnsafeCurrentTask { $0?.cancel() }
        }
        return try await checker.openSystemSettings(for: .camera, options: .none)
      }
      do {
        _ = try await task.value
        XCTFail("A cancelled call must throw")
      } catch is CancellationError {
        continue
      }
    }
  }

  func testLegacyConformerUsesDefaultSettingsOverloadAndValidatesItsResult() async throws {
    let legacy: any PermissionChecking = LegacySettingsChecker(result: .supported(true))
    let result = try await legacy.openSystemSettings(for: .camera, options: .none)
    XCTAssertEqual(result, .supported(true))

    let malformedCapability = PermissionCapability(
      supportsStatusCheck: false, supportsRequest: false,
      systemSettingsURL: URL(string: "relative/path"), requiresRelaunch: false)
    let malformed: any PermissionChecking = LegacySettingsChecker(
      result: .unsupported(malformedCapability))
    do {
      _ = try await malformed.openSystemSettings(for: .camera, options: .none)
      XCTFail("Malformed results from legacy conformers must throw")
    } catch let error as PermissionContractError {
      XCTAssertEqual(error.code, "invalidResult")
    }
  }
}

private func makeEnvironment(
  platform: PermissionPlatform = .macOS,
  openURL: @escaping @Sendable (URL) -> Bool
) -> PermissionEnvironment {
  PermissionEnvironment(
    platform: platform,
    status: { _, _ in .supported(.unknown) },
    requestAccess: { _, _ in .failed(.apiUnavailable) },
    openURL: openURL
  )
}

private struct LegacySettingsChecker: PermissionChecking {
  let result: PermissionOperationResult<Bool>

  func status(for _: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    .supported(.unknown)
  }

  func requestAccess(for _: PermissionType, options _: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  {
    .failed(.apiUnavailable)
  }

  func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    result
  }
}
