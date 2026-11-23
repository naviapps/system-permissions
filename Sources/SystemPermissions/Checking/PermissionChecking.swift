import Foundation

/// Read-only capability for checking permission status.
/// Implementations must not request access or open System Settings from a status check.
public protocol PermissionStatusChecking: Sendable {
  /// Platform used for default permission options. Existing implementations default to macOS.
  var platform: PermissionPlatform { get }

  /// Returns the current status for a permission type.
  func status(for type: PermissionType, options: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
}

/// Contract for permission status, request, and System Settings opening behavior.
public protocol PermissionChecking: PermissionStatusChecking {
  /// Requests access and returns the resulting status.
  func requestAccess(for type: PermissionType, options: PermissionOptions) async
    -> PermissionOperationResult<PermissionStatus>
  /// Attempts to open System Settings for the permission type.
  func openSystemSettings(for type: PermissionType) -> PermissionOperationResult<Bool>
  /// Validates a Settings request before invoking effects and throws when cancelled.
  func openSystemSettings(for type: PermissionType, options: PermissionOptions) async throws
    -> PermissionOperationResult<Bool>
}

extension PermissionStatusChecking {
  public var platform: PermissionPlatform { .macOS }

  /// Convenience overload that uses the default options for the permission type.
  public func status(for type: PermissionType) async -> PermissionOperationResult<PermissionStatus>
  {
    await status(for: type, options: type.defaultOptions(on: platform))
  }
}

extension PermissionChecking {
  /// Convenience overload that uses the default options for the permission type.
  public func requestAccess(for type: PermissionType) async -> PermissionOperationResult<
    PermissionStatus
  > {
    await requestAccess(for: type, options: type.defaultOptions(on: platform))
  }

  /// Validates options in Rust and uses the conformer's synchronous Settings operation.
  public func openSystemSettings(for type: PermissionType, options: PermissionOptions) async throws
    -> PermissionOperationResult<Bool>
  {
    try validatedOpenSystemSettings(for: type, options: options) { _ in
      openSystemSettings(for: type)
    }
  }

  func validatedOpenSystemSettings(
    for type: PermissionType,
    options: PermissionOptions,
    open: (URL) -> PermissionOperationResult<Bool>
  ) throws -> PermissionOperationResult<Bool> {
    try Task.checkCancellation()
    let admission = try NativePermissions.call(
      [
        "op": "admitSettings", "platform": platform.rawValue,
        "permission": NativePermissions.object(type.descriptor),
        "options": NativePermissions.object(options),
      ], as: SettingsAdmission.self)
    try Task.checkCancellation()
    if let result = admission.result { return result }
    guard let url = admission.capability?.systemSettingsURL else {
      throw PermissionContractError(code: "invalidResult", message: nil)
    }
    let result = open(url)
    try Task.checkCancellation()
    return try NativePermissions.call([
      "op": "validateSettingsResult", "result": NativePermissions.object(result),
    ])
  }
}

private struct SettingsAdmission: Decodable {
  let capability: PermissionCapability?
  let result: PermissionOperationResult<Bool>?
}
