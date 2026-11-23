import CSystemPermissions
import Foundation

/// Copies owned C results before releasing them. JSON is the shared Rust contract.
package enum NativePermissions {
  package typealias Failure = PermissionContractError

  package static func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
  }

  package static func call<T: Decodable>(_ request: [String: Any], as _: T.Type = T.self) throws
    -> T
  {
    try call(JSONSerialization.data(withJSONObject: request))
  }

  package static func decodeDescriptor(_ data: Data) throws -> PermissionDescriptor {
    let prefix = #"{"op":"validateDescriptor","permission":"#
    guard data.count <= 1024 * 1024 - prefix.utf8.count - 1 else {
      throw Failure(code: "inputTooLarge", message: nil)
    }
    // Rust validates the entire closed command, retaining the descriptor's original JSON bytes.
    var request = Data(prefix.utf8)
    request.append(data)
    request.append(0x7d)
    return try call(request)
  }

  private static func call<T: Decodable>(_ data: Data) throws -> T {
    return try data.withUnsafeBytes { bytes in
      try decode(
        system_permissions_call(bytes.bindMemory(to: UInt8.self).baseAddress, data.count),
        as: T.self)
    }
  }

  package static func decode<T: Decodable>(_ owner: OpaquePointer?, as _: T.Type) throws -> T {
    guard let owner else {
      throw Failure(code: "unavailable", message: "Native result allocation failed.")
    }
    defer { system_permissions_result_free(owner) }
    let count = system_permissions_result_len(owner)
    guard count <= 4 * 1024 * 1024, let bytes = system_permissions_result_data(owner) else {
      throw Failure(code: "invalidResult", message: "Invalid native result view.")
    }
    let data = Data(bytes: bytes, count: count)
    guard system_permissions_result_status(owner) == 0 else {
      throw try JSONDecoder().decode(Failure.self, from: data)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}

/// Rust-owned generations and commits. The adapter owns scheduling and UI projection only.
package final class PermissionState {
  private let owner: OpaquePointer

  private init() throws {
    guard let owner = system_permissions_store_new() else {
      throw NativePermissions.Failure(
        code: "unavailable", message: "Native permission store allocation failed.")
    }
    self.owner = owner
  }

  deinit { system_permissions_store_free(owner) }

  package struct Entry: Decodable {
    package let permission: PermissionDescriptor
    package let result: PermissionOperationResult<PermissionStatus>
  }
  package struct Snapshot: Decodable { package let values: [Entry] }
  struct Observation: Decodable {
    let result: PermissionOperationResult<PermissionStatus>
    let previousResult: PermissionOperationResult<PermissionStatus>?
  }
  package struct RefreshAdmission: Decodable {
    package let permission: PermissionDescriptor
    package let token: UInt64
  }
  package struct ScopedAdmission: Decodable {
    package enum Kind: String, Decodable {
      case untracked, invalidOptions, isolated, suppressed, stored
    }
    package let kind: Kind
    package let token: UInt64?
  }
  package enum OperationKind: String {
    case refresh
    case request
  }
  private struct Finished: Decodable { let finished: Bool }
  private struct Applied: Decodable {
    let changed: Bool
  }

  package static func tracking(_ types: [PermissionType]) throws
    -> (state: PermissionState, snapshot: Snapshot)
  {
    let state = try PermissionState()
    let snapshot: Snapshot = try state.call([
      "op": "track", "permissions": types.map { try NativePermissions.object($0.descriptor) },
    ])
    return (state, snapshot)
  }

  package func admitScoped(
    _ type: PermissionType, options: PermissionOptions, kind: OperationKind, cancelled: Bool
  ) throws -> ScopedAdmission {
    try call([
      "op": "admitScoped", "permission": NativePermissions.object(type.descriptor),
      "options": NativePermissions.object(options), "kind": kind.rawValue, "cancelled": cancelled,
    ])
  }

  package func admitAllRefreshes() throws -> [RefreshAdmission] {
    try call(["op": "admitAllRefreshes"])
  }

  package func finish(_ token: UInt64) throws -> Bool {
    try call(["op": "finish", "token": token], as: Finished.self).finished
  }

  package func apply(
    _ updates: [(PermissionType, UInt64, PermissionOperationResult<PermissionStatus>)]
  ) throws -> Bool {
    let values: [[String: Any]] = try updates.map {
      [
        "permission": try NativePermissions.object($0.0.descriptor), "token": $0.1,
        "result": try NativePermissions.object($0.2),
      ]
    }
    let result: Applied = try call(["op": "apply", "updates": values, "cancelled": false])
    return result.changed
  }

  package func snapshot() throws -> Snapshot { try call(["op": "snapshot"]) }

  func recordObservation(
    _ type: PermissionType, result: PermissionOperationResult<PermissionStatus>
  ) throws -> Observation {
    try call([
      "op": "recordObservation", "permission": NativePermissions.object(type.descriptor),
      "result": NativePermissions.object(result),
    ])
  }

  private func call<T: Decodable>(_ request: [String: Any], as _: T.Type = T.self) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: request)
    return try data.withUnsafeBytes { bytes in
      try NativePermissions.decode(
        system_permissions_store_call(
          owner, bytes.bindMemory(to: UInt8.self).baseAddress, data.count), as: T.self)
    }
  }
}
