import Combine
import SystemPermissions
import SystemPermissionsMacOS
import XCTest

@MainActor
final class SystemPermissionsMacOSPublicAPITests: XCTestCase {
  func testDocumentationSampleEntrypointsCompileFromPublicImport() async throws {
    let checker = PermissionChecker()
    let store = try SystemPermissionsStore(
      trackedTypes: [.accessibility, .screenRecording],
      permissionChecker: PublicPermissionChecker()
    )

    assertSendable(checker)
    assertObservableObject(store)

    XCTAssertEqual(store.trackedTypes, [.accessibility, .screenRecording])
    _ = try await store.refreshAll()
    _ = try await store.refresh(.screenRecording)
    _ = try await store.requestAccess(for: .accessibility)
    _ = store.status(for: .screenRecording)
    _ = store.allowsAccess(.accessibility)
  }
}

private func assertSendable<Value: Sendable>(_: Value) {}

private func assertObservableObject<Value: ObservableObject>(_: Value) {}

private struct PublicPermissionChecker: PermissionChecking {
  func status(
    for _: PermissionType,
    options _: PermissionOptions
  ) async -> PermissionOperationResult<PermissionStatus> {
    .supported(.unknown)
  }

  func requestAccess(
    for _: PermissionType,
    options _: PermissionOptions
  ) async -> PermissionOperationResult<PermissionStatus> {
    .supported(.unknown)
  }

  func openSystemSettings(for _: PermissionType) -> PermissionOperationResult<Bool> {
    .supported(true)
  }
}
