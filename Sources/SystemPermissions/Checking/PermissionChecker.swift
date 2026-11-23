/// Default implementation that delegates permission operations to an environment.
public struct PermissionChecker: PermissionChecking {
  private let environment: PermissionEnvironment
  public var platform: PermissionPlatform { environment.platform }

  /// Creates a checker backed by the given environment.
  public init(environment: PermissionEnvironment) {
    self.environment = environment
  }

  /// Returns the current status for a permission type.
  public func status(
    for type: PermissionType,
    options: PermissionOptions
  ) async -> PermissionOperationResult<PermissionStatus> {
    await check(type, options: options, request: false) {
      await environment.status(for: type, options: $0)
    }
  }

  /// Requests access to a permission type.
  public func requestAccess(
    for type: PermissionType,
    options: PermissionOptions
  ) async -> PermissionOperationResult<PermissionStatus> {
    await check(type, options: options, request: true) {
      await environment.requestAccess(for: type, options: $0)
    }
  }

  /// Opens System Settings for the permission type.
  public func openSystemSettings(for type: PermissionType) -> PermissionOperationResult<Bool> {
    let capability = type.capability(on: platform)
    guard let url = capability.systemSettingsURL else {
      return .unsupported(capability)
    }
    return environment.openURL(url) ? .supported(true) : .failed(.openFailed)
  }

  /// Opens the Rust-validated Settings destination with cancellation checks.
  public func openSystemSettings(for type: PermissionType, options: PermissionOptions) async throws
    -> PermissionOperationResult<Bool>
  {
    try validatedOpenSystemSettings(for: type, options: options) { url in
      environment.openURL(url) ? .supported(true) : .failed(.openFailed)
    }
  }

  private func check(
    _ type: PermissionType, options: PermissionOptions, request: Bool,
    effect: (PermissionOptions) async -> PermissionOperationResult<PermissionStatus>
  ) async -> PermissionOperationResult<PermissionStatus> {
    guard !Task.isCancelled else { return .supported(.unknown) }
    guard
      let admission = try? NativePermissions.call(
        [
          "op": "admitAccess", "platform": platform.rawValue, "request": request,
          "permission": NativePermissions.object(type.descriptor),
          "options": NativePermissions.object(options),
        ], as: AccessAdmission.self)
    else { return .failed(.invalidOptions) }
    if let completed = admission.result { return completed }
    guard let options = admission.options else { return .failed(.invalidOptions) }
    let result = await effect(options)
    guard !Task.isCancelled else { return .supported(.unknown) }
    return result.validatedForState()
  }
}

private struct AccessAdmission: Decodable {
  let options: PermissionOptions?
  let result: PermissionOperationResult<PermissionStatus>?
}
