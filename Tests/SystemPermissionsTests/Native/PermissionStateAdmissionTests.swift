import SystemPermissions
import XCTest

final class PermissionStateAdmissionTests: XCTestCase {
  func testScopedAdmissionBridgesTokenCommitAndSnapshot() throws {
    let state = try PermissionState(types: [.camera])
    let admission = try state.admitScoped(.camera, options: .none, kind: .refresh, cancelled: false)
    XCTAssertEqual(admission.kind, .stored)
    let token = try XCTUnwrap(admission.token)
    XCTAssertTrue(try state.apply([(.camera, token, .supported(.limited))]))
    XCTAssertTrue(try state.finish(token))
    let entry = try XCTUnwrap(state.snapshot().values.first)
    XCTAssertEqual(try PermissionType(descriptor: entry.permission), .camera)
    XCTAssertEqual(entry.result, .supported(.limited))
  }
}
